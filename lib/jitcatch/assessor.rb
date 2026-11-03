# frozen_string_literal: true

module JitCatch
  # Rule-based filter. It does not decide intended-versus-regression.
  # That judgment needs the change intent and belongs to the agent.
  class Assessor
    ARITY = /wrong number of arguments|missing keywords?: |unknown keywords?: /

    def self.apply(doc)
      new(doc).apply
    end

    # The name a test writes to reach a method: its bare name, or
    # `Owner.new` for a constructor.
    def self.mention_of(qualified)
      qualifier, sep, bare = SourceIndex.split_qualified(qualified)
      constructor = (sep == "#" && bare == "initialize") || (sep == "." && bare == "new")
      constructor ? "#{qualifier.split("::").last}.new" : bare
    end

    def initialize(doc)
      @doc = doc
      @methods = Array(doc["methods"])
      @constants = Array(doc["constants"])
    end

    def apply
      tests = Array(@doc["tests"]).map { |test| strip(test) }
      tests.each do |test|
        if test["classification"] == "candidate"
          method, pool = related_method(test)
          reason = discard_reason(test, method)
          test["method_id"] = method&.dig("id")
          test["method_ids"] = pool.map { |item| item["id"] }.sort
          test["disposition"] = reason ? "discarded" : "reported"
          test["tags"] = tags_for(test, method, reason)
          test["tags"] = (test["tags"] + ["related:guess"]).sort if pool.size > 1
        else
          test["method_id"] = nil
          test["method_ids"] = []
          test["disposition"] = test["classification"]
          test["tags"] = []
        end
      end
      assign_candidate_ids(tests)
      @doc.merge(
        "tests" => tests,
        "counts" => counts(tests)
      )
    end

    private

    def strip(test)
      test.reject { |key, _| %w[method_id method_ids tags disposition candidate_id].include?(key) }
    end

    def assign_candidate_ids(tests)
      rows = tests.select { |test| test["classification"] == "candidate" }.sort_by { |test| test["id"] }
      width = [2, rows.size.to_s.length].max
      rows.each_with_index { |test, index| test["candidate_id"] = format("c%0#{width}d", index + 1) }
      tests.each { |test| test["candidate_id"] ||= nil }
    end

    def counts(tests)
      {
        "generated" => tests.size,
        "no_signal" => tests.count { |test| test["classification"] == "no_signal" },
        "fail_on_base" => tests.count { |test| test["classification"] == "fail_on_base" },
        "candidates" => tests.count { |test| test["classification"] == "candidate" },
        "flaky" => tests.count { |test| test["classification"] == "flaky" },
        "discarded" => tests.count { |test| test["disposition"] == "discarded" },
        "reported" => tests.count { |test| test["disposition"] == "reported" }
      }
    end

    def discard_reason(test, method)
      head = test["head"] || {}
      return "timeout" if head["status"] == "timeout" || head["error_class"] == "Timeout"
      return "load_error" if head["error_class"] == "LoadError"

      symbol = missing_symbol(head)
      if %w[NameError NoMethodError].include?(head["error_class"]) && symbol && removed_symbol?(symbol)
        return "signature_change"
      end

      if arity_error?(head)
        target = method_from_backtrace(test) || method
        # A removed method leaves the inherited one, whose arity differs.
        return "signature_change" if target && %w[changed removed].include?(target["signature"])
      end

      nil
    end

    # assert_raises and RSpec's raise_error turn an unexpected ArgumentError
    # into an assertion failure, so the call that no longer fits its method
    # looks like a claim the test made.
    def arity_error?(head)
      message = head["message"].to_s
      case head["error_class"]
      when "ArgumentError" then message.match?(/\A(?:#{ARITY})/)
      when "Minitest::Assertion" then message.match?(/exception expected, not\nClass: <ArgumentError>\nMessage: <"(?:#{ARITY})/)
      when "RSpec::Expectations::ExpectationNotMetError" then message.match?(/\Aexpected .*, got #<ArgumentError: (?:#{ARITY})/)
      else false
      end
    end

    def tags_for(test, method, reason)
      head = test["head"] || {}
      tags = []
      tags << (reason ? "discard:#{reason}" : "report")
      tags << "assertion" if head["status"] == "fail"
      if head["error_class"] && head["status"] != "fail"
        tags << "error:#{head["error_class"]}"
      end
      tags.concat(touch_tags(test, method))
      tags.uniq.sort
    end

    def touch_tags(test, method)
      mentions = Array(test["mentions"])
      tags = []
      changed_mentions = @methods.map { |item| mention(item) }
      gem = origin_gem(test)
      direct = method && gem.nil? && (mentions.include?(mention(method)) || frame_hits?(test, method))
      tags << "touches:changed_method" if direct
      tags << "touches:changed_dependency" if gem && Array(@doc["dependencies"]).any? { |dep| dep["gem"] == gem }
      tags << "touches:changed_constant" if (mentions & @constants.map { |const| const["bare_name"] }).any?
      upstream = @methods.flat_map { |item| Array(item["reachable_from"]).map { |name| bare(name) } }
      callers = (mentions & upstream) - changed_mentions
      tags << "touches:unchanged_caller" if callers.any?
      tags
    end

    # The gem an error came from, when its first frame outside the candidate
    # file is inside an installed gem. Such an error says the gem broke, not
    # that a changed method returned a new value.
    def origin_gem(test)
      return nil unless test.dig("head", "status") == "error"

      frame = frames(test).find { |item| !item["file"].to_s.start_with?(".jitcatch/") }
      frame && frame["file"].to_s[%r{(?:\A|/)gems/([^/]+?)-\d[^/]*/}, 1]
    end

    # The pick and every changed method the same evidence points at. Two or
    # more in the pool means the evidence cannot tell them apart, so the
    # pick is a guess: a test that names only unchanged callers reaches
    # every changed method below them.
    def related_method(test)
      head = test["head"] || {}
      symbol = missing_symbol(head)
      if symbol
        hits = @methods.select { |item| item["bare_name"] == symbol }
        return [lowest(hits), hits] if hits.any?
      end
      framed = @methods.select { |item| frame_hits?(test, item) }
      return [method_from_backtrace(test), framed] if framed.any?

      mentions = Array(test["mentions"])
      mentioned = @methods.select { |item| mentions.include?(mention(item)) }
      # Almost every test builds its object with `.new`, so a changed
      # constructor is the related method only when nothing else points.
      constructors, named = mentioned.partition { |item| mention(item).end_with?(".new") }
      return [most_downstream(named), named] if named.any?

      via_caller = @methods.select { |item|
        upstream = Array(item["reachable_from"]).map { |name| bare(name) }
        (mentions & upstream).any?
      }
      pool = via_caller.empty? ? constructors : via_caller
      [most_downstream(pool), pool]
    end

    def method_from_backtrace(test)
      frames(test).each do |frame|
        hit = @methods.find { |item| frame_hits_method?(frame, item) }
        return hit if hit
      end
      nil
    end

    def frame_hits?(test, method)
      frames(test).any? { |frame| frame_hits_method?(frame, method) }
    end

    def frame_hits_method?(frame, method)
      return false unless frame["file"] == method["file"]

      line = frame["line"]
      ranges = []
      ranges << (method["start_line"]..method["end_line"]) if method["start_line"] && method["end_line"]
      ranges << (method["old_start"]..method["old_end"]) if method["old_start"] && method["old_end"]
      ranges.any? { |range| range.cover?(line) }
    end

    def frames(test)
      Array(test.dig("head", "backtrace"))
    end

    def missing_symbol(head)
      message = head["message"].to_s
      if (match = message.match(/undefined method [`']([^`']+)[`']/))
        match[1]
      elsif (match = message.match(/undefined local variable or method [`']([^`']+)[`']/))
        match[1]
      elsif (match = message.match(/uninitialized constant ([\w:]+)/))
        match[1]
      end
    end

    def removed_symbol?(symbol)
      removed_methods = @methods.select { |item| item["change"] == "removed" || item["signature"] == "removed" }
      return true if removed_methods.any? { |item| item["bare_name"] == symbol }

      removed_constants = @constants.select { |item| item["change"] == "removed" }
      removed_constants.any? { |item| item["bare_name"] == symbol || item["name"] == symbol || symbol.end_with?("::#{item["bare_name"]}") }
    end

    # A catching test passed on the old code, so a method that already existed
    # outranks one the diff only added. Among those, the method furthest
    # downstream (the one other changed methods call into) is the usual source
    # of the new value.
    def most_downstream(items)
      items.min_by do |item|
        others = items.reject { |other| other["id"] == item["id"] }
        covered = others.count { |other| Array(item["reachable_from"]).include?(other["name"]) }
        [preference(item), -covered, item["id"].to_s]
      end
    end

    def preference(item)
      case item["change"]
      when "modified", "affected" then 0
      when "removed" then 1
      else 2
      end
    end

    def mention(item)
      self.class.mention_of(item["name"].to_s)
    end

    def lowest(items)
      items.min_by { |item| item["id"].to_s }
    end

    def bare(qualified)
      SourceIndex.split_qualified(qualified).last
    end
  end
end
