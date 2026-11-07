# frozen_string_literal: true

module JitCatch
  # Turns an ERB template into Ruby that Prism can parse, line for line, so
  # a call in a template keeps the line it has there. Text outside the tags
  # becomes blank lines, and the value of each `<%=` tag goes to a call
  # named `__erb_out__`, so a reader can tell printed values from code.
  module Template
    OUTPUT = :__erb_out__

    module_function

    def as_ruby(text)
      out = +""
      pos = 0
      text.scan(/<%(=|-|#)?(.*?)-?%>/m) do
        match = Regexp.last_match
        out << ("\n" * text[pos...match.begin(0)].count("\n"))
        kind = match[1]
        code = match[2]
        if kind == "#"
          out << ("\n" * code.count("\n"))
        elsif kind == "="
          out << "#{OUTPUT} #{code.strip};"
          out << ("\n" * code.count("\n"))
        else
          out << code << ";"
        end
        pos = match.end(0)
      end
      out
    end

    def template?(path)
      path.end_with?(".erb")
    end
  end
end
