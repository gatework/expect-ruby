# frozen_string_literal: true

require "shellwords"

# 会话终端的模式和窗口尺寸接口；人工接管期间的临时恢复由 interaction.rb 负责。
class Expect
  # 查询可恢复的终端模式字符串，或通过系统 stty 设置模式；参数按数组传递，不经 shell。
  # 非终端返回空字符串；命令不存在或执行失败抛出 IOError，管道在所有退出路径关闭。
  def stty(*modes)
    return "" unless tty?

    modes = modes.flat_map { |mode| Shellwords.split(mode.to_s) }
    modes = ["-g"] if modes.empty?
    reader, sink = IO.pipe
    child = Process.spawn("stty", *modes, in: to_io, out: sink, err: sink)
    sink.close
    output = reader.read
    _, status = Process.waitpid2(child)
    raise IOError, "stty failed: #{output.strip}" unless status.success?

    output.strip
  rescue Errno::ENOENT
    raise IOError, "stty executable not found in PATH; install the system terminal utilities"
  ensure
    reader&.close unless reader&.closed?
    sink&.close unless sink&.closed?
  end

  # 读取终端的 [行数, 列数]；底层并非终端或句柄已关闭时保留原生 IO 异常。
  def winsize = to_io.winsize

  # 更新终端尺寸，由内核通知前台进程。
  def winsize=(size)
    to_io.winsize = size
  end
end
