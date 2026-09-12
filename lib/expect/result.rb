# frozen_string_literal: true

class Expect
  # 保存一次等待的结果，保留 Struct 原生数组、Hash 转换和模式解构能力。
  # number 仅在文本匹配时存在；error 为 :timeout、:eof 或原始 IO 异常，文本字段均为字节串。
  Result = Struct.new(:number, :error, :match, :before, :after, :session, :captures, keyword_init: true) do
    # 是否命中文本模式；事件不会返回模式序号。
    def matched? = !number.nil?
    # 是否因本次等待期限到达而返回。
    def timeout? = error == :timeout
    # 是否读取源已经结束；子进程是否退出仍应查询会话的 process_status。
    def eof? = error == :eof
  end
end
