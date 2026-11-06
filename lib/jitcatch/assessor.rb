# frozen_string_literal: true

module JitCatch
  # Rule-based filter. It does not decide intended-versus-regression.
  # That judgment needs the change intent and belongs to the agent.
  class Assessor
    ARITY = /wrong number of arguments|missing keywords?: |unknown keywords?: |struct size differs/
    # Active Record's errors for a database it cannot reach. Each checkout
    # uses its own numbered test database, so one that was never created
    # fails on that side alone, which says nothing about the change.
    NO_DATABASE = %w[ActiveRecord::NoDatabaseError ActiveRecord::ConnectionNotEstablished ActiveRecord::DatabaseConnectionError].freeze
    # A database that `db:create` made has no tables until something loads
    # the schema, which a test helper without `maintain_test_schema!` never
    # does. Each adapter words the missing table its own way, and the
    # SQLite adapter's own column lookup says "Could not find table".
    NO_TABLE = /\APG::UndefinedTable: |\ASQLite3::SQLException: no such table: |\ACould not find table '|Table '[^']*' doesn't exist/

    def self.no_table?(result)
      result["error_class"] == "ActiveRecord::StatementInvalid" && NO_TABLE.match?(result["message"].to_s)
    end

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
      @callers = @methods.flat_map { |item| reached_by(item) }.uniq
      @tests_dir = doc["tests_dir"]
    end

    def apply
      tests = Array(@doc["tests"]).map { |test| strip(test) }
      tests.each do |test|
        if test["classification"] == "candidate"
          method, pool, tied = related_method(test)
          broken = broken_call(test, method)
          call = broken&.frame
          reason = discard_reason(test, call)
          test["out_of_date"] = reason == "signature_change" ? out_of_date(broken) : nil
          test["method_id"] = tied ? nil : method&.dig("id")
          test["method_ids"] = pool.map { |item| item["id"] }.sort
          test["disposition"] = reason ? "discarded" : "reported"
          test["tags"] = tags_for(test, tied ? pool : [method].compact, reason, call)
          test["tags"] = (test["tags"] + ["related:guess"]).sort if pool.size > 1
          test["dynamic_call"] = method ? nil : dynamic_call(test)
          test["tags"] = (test["tags"] + ["related:dynamic"]).sort if test["dynamic_call"]
        else
          test["method_id"] = nil
          test["method_ids"] = []
          test["dynamic_call"] = nil
          test["out_of_date"] = nil
          test["disposition"] = test["classification"]
          test["tags"] = []
        end
      end
      assign_candidate_ids(tests)
      @doc.merge(
        "tests" => tests,
        "counts" => counts(tests),
        "untested" => tests.count { |test| self.class.untested?(test, @doc["timeout_s"]) }
      )
    end

    # A row whose side timed out, or found no database or no table, says
    # nothing about the change, whatever its classification.
    def self.untested?(test, timeout_s)
      !untested_causes(test, timeout_s).empty?
    end

    UNTESTED_CAUSES = {
      "timed out" => ->(result) { result["status"] == "timeout" },
      "found no database" => ->(result) { NO_DATABASE.include?(result["error_class"]) },
      "found no table" => ->(result) { no_table?(result) }
    }.freeze

    def self.untested_causes(test, timeout_s)
      results = %w[base head].map { |side| test[side] || {} }
      causes = UNTESTED_CAUSES.select { |_cause, seen| results.any?(&seen) }.keys
      head_only_timeout?(test, timeout_s) ? causes - ["timed out"] : causes
    end

    # Base passed in at most half the time head ran out of, so a slow boot
    # does not explain head's timeout: head may loop or wait forever, as a
    # wait that checks a clock the test froze does.
    def self.head_only_timeout?(test, timeout_s)
      base = test["base"] || {}
      seconds = base["seconds"]
      test.dig("head", "status") == "timeout" && base["status"] == "pass" &&
        seconds.is_a?(Numeric) && timeout_s.is_a?(Numeric) && seconds * 2 <= timeout_s
    end

    # A run where no row compared base with head, and the environment hid
    # at least one row that might have, tested nothing, which must not read
    # like a change with no finding. Its fix is outside the candidates. A
    # run whose rows all failed on base with nothing hidden is the
    # candidates' to fix, and each row's `base:` line says why.
    def self.untested_run?(doc)
      tests = Array(doc["tests"])
      doc["untested"].to_i.positive? && tests.none? { |test| compared?(test, doc["timeout_s"]) }
    end

    # Base passed and neither side hit an untested cause.
    def self.compared?(test, timeout_s)
      test.dig("base", "status") == "pass" && !untested?(test, timeout_s)
    end

    private

    def strip(test)
      test.reject { |key, _| %w[method_id method_ids dynamic_call tags disposition candidate_id out_of_date].include?(key) }
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

    def discard_reason(test, call)
      head = test["head"] || {}
      timed_out = head["status"] == "timeout" || head["error_class"] == "Timeout" || test.dig("base", "status") == "timeout"
      return "timeout" if timed_out && !self.class.head_only_timeout?(test, @doc["timeout_s"])
      return "load_error" if head["error_class"] == "LoadError"
      return "no_database" if NO_DATABASE.include?(head["error_class"])
      return "no_table" if self.class.no_table?(head)
      # Only a call the test wrote is a claim the new signature voids. With
      # no frame to say who called, the test is assumed to have.
      return "signature_change" if call && (call.empty? || test_frame?(call))

      nil
    end

    # A call the change broke: the frame that made it (an empty hash when the
    # error kept none), the changed method or constant it called, and what
    # changed about it.
    Broken = Data.define(:frame, :subject, :change)

    # A call to a removed name, or one whose arguments no longer fit. Nil
    # when no call broke.
    def broken_call(test, method)
      error = raised(test)
      symbol = missing_symbol(error)
      if symbol && (subject = removed_subject(symbol))
        return Broken.new(error.frames.first || {}, subject, "removed")
      end
      return nil unless arity_error?(error)

      target = method_from_backtrace(test) || method
      # A removed method leaves the inherited one, whose arity differs.
      return changed_class_call(test, error) unless target && %w[changed removed].include?(target["signature"])

      # The first frame is the callee's own line when Ruby defines it, so
      # the caller is the next one.
      frame = error.frames.first(2).find { |item| test_frame?(item) } || error.frames[1] || error.frames.first || {}
      Broken.new(frame, target, target["signature"] == "removed" ? "removed" : "parameters")
    end

    # Ruby defines `new` of a Data or Struct class in C, so a member the
    # change added or dropped fails the test's own call with no frame of the
    # class: the first frame is the test's, and the test names the class.
    def changed_class_call(test, error)
      frame = error.frames.first
      return nil unless frame && test_frame?(frame)

      mentions = Array(test["mentions"])
      constant = lowest(@constants.select { |item| item["change"] == "modified" && mentions.include?(item["bare_name"]) })
      constant && Broken.new(frame, constant, "definition")
    end

    def out_of_date(broken)
      return nil if broken.nil?

      frame = broken.frame
      { "id" => broken.subject["id"], "name" => broken.subject["name"], "change" => broken.change,
        "call" => frame["file"] && [frame["file"], frame["line"]].compact.join(":") }
    end

    Raised = Data.define(:error_class, :message, :frames)

    # The error a call raised. assert_raises and RSpec's raise_error turn
    # an error of another class into an assertion failure, so it is read
    # back out of the failure message. Both parsers put the assertion's own
    # line before the frames of the error it caught.
    def raised(test)
      head = test["head"] || {}
      message = head["message"].to_s
      case head["error_class"]
      when "Minitest::Assertion"
        if (match = message.match(/exception expected, not\nClass: <([\w:]+)>\nMessage: <(.*)>$/))
          return Raised.new(match[1], undump(match[2]), frames(test).drop(1))
        end
      when "RSpec::Expectations::ExpectationNotMetError"
        if (match = message.match(/\Aexpected .*, got #<([\w:]+): (.*)>$/))
          return Raised.new(match[1], match[2], frames(test).drop(1))
        end
      end
      Raised.new(head["error_class"], message, frames(test))
    end

    def undump(quoted)
      quoted.undump
    rescue RuntimeError
      quoted
    end

    def arity_error?(error)
      error.error_class == "ArgumentError" && error.message.match?(/\A(?:#{ARITY})/)
    end

    def test_frame?(frame)
      !@tests_dir.nil? && frame["file"].to_s.start_with?("#{@tests_dir}/")
    end

    def caller_tag(call)
      return nil if call.nil? || call.empty? || test_frame?(call)

      changed = @methods.any? { |item|
        %w[modified added].include?(item["change"]) && item["file"] == call["file"] &&
          item["start_line"] && item["end_line"] && (item["start_line"]..item["end_line"]).cover?(call["line"])
      }
      edited = Array(@doc.dig("changed_lines", call["file"])).any? { |first, last| (first..last).cover?(call["line"]) }
      "caller:#{changed || edited ? "changed" : "unchanged"}:#{call["file"]}:#{call["line"]}"
    end

    def tags_for(test, judged, reason, call)
      head = test["head"] || {}
      tags = []
      tags << (reason ? "discard:#{reason}" : "report")
      tags << caller_tag(call)
      tags << "assertion" if head["status"] == "fail"
      tags << "message_varies" if test["message_varies"]
      tags << "head_only_timeout" if self.class.head_only_timeout?(test, @doc["timeout_s"])
      if head["error_class"] && head["status"] != "fail"
        tags << "error:#{head["error_class"]}"
      end
      tags.concat(touch_tags(test, judged))
      tags.compact.uniq.sort
    end

    # A row with no pick judges every method of its pool, so its tags do not
    # depend on which tied method has the lower id.
    def touch_tags(test, judged)
      mentions = Array(test["mentions"])
      tags = []
      changed_mentions = @methods.map { |item| mention(item) }
      gem = origin_gem(test)
      direct = gem.nil? && judged.any? { |method|
        (mentioned?(method, mentions) && sent_to_named_receivers([method], mentions).any?) || frame_hits?(test, method)
      }
      tags << "touches:changed_method" if direct
      tags << "touches:changed_dependency" if gem && Array(@doc["dependencies"]).any? { |dep| dep["gem"] == gem }
      tags << "touches:changed_constant" if (mentions & @constants.map { |const| const["bare_name"] }).any?
      # A bare name that a changed method shares counts as that method; one
      # the test sends to a named class counts as that class's.
      callers = (@callers - @methods.map { |item| item["name"] }).select { |name|
        sent_to?(name, mentions) && (receivers_of(name, mentions).any? || !changed_mentions.include?(bare(name)))
      }
      tags << "touches:unchanged_caller" if callers.any?
      tags
    end

    # The gem an error came from, when its first frame outside the candidate
    # file is inside an installed gem. Such an error says the gem broke, not
    # that a changed method returned a new value.
    def origin_gem(test)
      return nil unless test.dig("head", "status") == "error"

      frame = frames(test).find { |item| !test_frame?(item) }
      frame && frame["file"].to_s[%r{(?:\A|/)gems/([^/]+?)-\d[^/]*/}, 1]
    end

    # The pick and every changed method the same evidence points at. Two or
    # more in the pool means the evidence cannot tell them apart, so the
    # pick is a guess: a test that names only unchanged callers reaches
    # every changed method below them.
    def related_method(test)
      symbol = missing_symbol(raised(test))
      if symbol
        hits = @methods.select { |item| item["bare_name"] == symbol }
        return [lowest(hits), hits] if hits.any?
      end
      framed = @methods.select { |item| frame_hits?(test, item) }
      # The innermost changed frame is where the error came from; the frames
      # outside it only called it.
      if framed.any?
        innermost = method_from_backtrace(test)
        return [innermost, [innermost]]
      end

      mentions = Array(test["mentions"])
      mentioned = sent_to_named_receivers(@methods.select { |item| mentioned?(item, mentions) }, mentions)
      # Almost every test builds its object with `.new`, so a changed
      # constructor is the related method only when nothing else points.
      constructors, named = mentioned.partition { |item| mention(item).end_with?(".new") }
      return guess(named) if named.any?

      via_caller = @methods.select { |item|
        upstream = reached_by(item).map { |name| bare(name) }
        (mentions & upstream).any?
      }
      sent = via_caller.select { |item| reached_by(item).any? { |name| sent_to?(name, mentions) } }
      via_caller = sent unless sent.empty?
      pool = via_caller.empty? ? constructors : via_caller
      guess(pool, depth_below_entry(pool, mentions))
    end

    # The pick, the pool, and whether only the id ordered the best two.
    # A tied pick still sets the tags, as it did when the id was shown.
    def guess(items, depths = {})
      ranked = items.sort_by { |item| guess_rank(item, items, depths) }
      tied = ranked.size > 1 && guess_rank(ranked[0], items, depths)[0...-1] == guess_rank(ranked[1], items, depths)[0...-1]
      [ranked.first, items, tied]
    end

    # A test that names the class it sends a method to (`Index.parse`,
    # `described_class.parse`) calls that class's method of the name, not
    # another class's. When no changed method of the name is on a class
    # the test names, the call may reach one through a superclass or a
    # module, so all of them stay, unless the named class's method is a
    # known caller of a changed method: the call stops there.
    def sent_to_named_receivers(items, mentions)
      items.group_by { |item| bare(item["name"]) }.flat_map do |_name, group|
        receivers = receivers_of(group.first["name"].to_s, mentions)
        hits = group.select { |item| sent_to?(item["name"].to_s, mentions) }
        hits.empty? && @callers.none? { |name| on_receiver?(name, receivers) } ? group : hits
      end
    end

    # Whether the test calls the method: on a class it names when it names
    # one for that method name, or by the bare name when it names none.
    def sent_to?(qualified, mentions)
      receivers = receivers_of(qualified, mentions)
      receivers.empty? ? mentions.include?(bare(qualified)) : on_receiver?(qualified, receivers)
    end

    def on_receiver?(qualified, receivers)
      qualifier, sep, name = SourceIndex.split_qualified(qualified)
      receivers.any? { |owner, owner_sep, owner_name| owner_name == name && sep == owner_sep && (qualifier == owner || qualifier.end_with?("::#{owner}")) }
    end

    def receivers_of(qualified, mentions)
      name = bare(qualified)
      mentions.map { |mention| SourceIndex.split_qualified(mention) }
        .select { |owner, _sep, bare_name| !owner.empty? && bare_name == name }
    end

    # With no related method, the call the test makes may still reach one
    # through a receiver the source does not name. That is said, not guessed.
    def dynamic_call(test)
      mentions = Array(test["mentions"])
      @methods.flat_map { |item| Array(item["dynamic_callers"]) }
        .sort_by { |caller| [caller["from"], caller["name"]] }
        .find { |caller| sent_to?(caller["from"], mentions) }
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

    # The frames are the head run's, so only head's lines of a method count.
    # A removed method has no lines on head.
    def frame_hits_method?(frame, method)
      return false unless frame["file"] == method["file"] && method["change"] != "removed"

      (method["start_line"]..method["end_line"]).cover?(frame["line"])
    end

    def frames(test)
      Array(test.dig("head", "backtrace"))
    end

    # The name a NameError says is missing. Another error, or an assertion,
    # can quote the same words without any lookup having failed.
    def missing_symbol(error)
      return nil unless %w[NameError NoMethodError].include?(error.error_class)

      message = error.message
      if (match = message.match(/undefined method [`']([^`']+)[`']/))
        match[1]
      elsif (match = message.match(/undefined local variable or method [`']([^`']+)[`']/))
        match[1]
      elsif (match = message.match(/uninitialized constant ([\w:]+)/))
        match[1]
      end
    end

    def removed_subject(symbol)
      removed_methods = @methods.select { |item| item["change"] == "removed" || item["signature"] == "removed" }
      method = lowest(removed_methods.select { |item| item["bare_name"] == symbol })
      return method if method

      removed_constants = @constants.select { |item| item["change"] == "removed" }
      lowest(removed_constants.select { |item| item["bare_name"] == symbol || item["name"] == symbol || symbol.end_with?("::#{item["bare_name"]}") })
    end

    # A catching test passed on the old code, so a method that already existed
    # outranks one the diff only added. Among those, the method furthest
    # downstream (the one other changed methods call into) is the usual source
    # of the new value. An edit that only adds a call to an added method
    # ranks with the added ones, since the value it routes is made below
    # it. Between two that no changed method links, the one
    # above more changed code is the likelier: a test that names a setup call
    # and the call it checks reaches the change through the second.
    #
    # A test that enters high, as a request spec or a CLI test does,
    # reaches the plumbing next to its entry point as well as the code its
    # assertion checks further down. On a CLI test of this repository and
    # a request spec of a Rails app, the method farthest from the entry
    # point the test calls was the one the failure came from in both, and
    # the lowest id in one, so depth ranks before the count below.
    def guess_rank(item, items, depths)
      others = items.reject { |other| other["id"] == item["id"] }
      covered = others.count { |other| reached_by(item).include?(other["name"]) }
      below = @methods.count { |other| reached_by(other).include?(item["name"]) }
      [preference(item), -covered, -depths.fetch(item["id"], 0), -below, item["id"].to_s]
    end

    # The fewest calls between each item and an entry point the test
    # names. A run file from before `caller_depths` existed has none.
    def depth_below_entry(items, mentions)
      items.to_h do |item|
        depths = Hash(item["caller_depths"]).filter_map { |name, depth| depth if mentions.include?(bare(name)) }
        [item["id"], depths.min || 0]
      end
    end

    def preference(item)
      return 2 if item["forwards_to_added"]

      case item["change"]
      when "modified", "affected", "moved" then 0
      when "removed" then 1
      else 2
      end
    end

    def mention(item)
      self.class.mention_of(item["name"].to_s)
    end

    # A test writes a constructor as `Box.new` or `A::Box.new`. The written
    # path names this class when its segments end the class's name, so
    # `A::Box.new` is not a mention of `B::Box#initialize`. A record builder
    # (`Box.create!`) or a factory the change document lists for the
    # constructor runs it too, and a save (`Box.create!`, `Box#save`) runs
    # a callback the model declares.
    def mentioned?(item, mentions)
      name = mention(item)
      calls = Array(item["builders"]) + Array(item["run_by"])
      if name.end_with?(".new")
        calls << "#{SourceIndex.split_qualified(item["name"].to_s).first}.new"
      elsif mentions.include?(name)
        return true
      end
      mentions.any? { |text| calls.any? { |call| SourceIndex.names_call?(text, call) } }
    end

    # Every method that reaches the item. A run file from before
    # `reached_by` existed holds only the capped `reachable_from`.
    def reached_by(item)
      Array(item["reached_by"] || item["reachable_from"])
    end

    def lowest(items)
      items.min_by { |item| item["id"].to_s }
    end

    def bare(qualified)
      SourceIndex.split_qualified(qualified).last
    end
  end
end
