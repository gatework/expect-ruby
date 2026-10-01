# frozen_string_literal: true

# 独立观察 io-console 修改前后的全部终端标志；系统命令仅用于验收，不属于库的运行时。
module TerminalProbe
  DARWIN_PENDIN = 0x20000000
  private_constant :DARWIN_PENDIN

  def self.configuration(io)
    state = IO.popen(["stty", "-g"], in: io, err: %i[child out], &:read).strip
    raise IOError, "terminal state query failed: #{state}" unless Process.last_status.success?
    return state unless RUBY_PLATFORM.include?("darwin")

    # PENDIN 是 Darwin 内核的暂态输入重显标记，不属于调用方设置的终端配置。
    state.sub(/lflag=([0-9a-f]+)/) do
      "lflag=#{(Regexp.last_match(1).to_i(16) & ~DARWIN_PENDIN).to_s(16)}"
    end
  end
end
