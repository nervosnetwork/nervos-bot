require 'uri'
require 'telegram/bot'

class AlertManager
  attr_reader :tg
  attr_reader :logger
  attr_reader :chat_id

  def initialize(opts = nil)
    opts ||= {}
    @logger = opts.fetch(:logger, Logger.new(STDOUT))
    if opts.include?(:tg)
      @tg = opts[:tg]
    else
      tg_token = opts.fetch(:tg_access_token, ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN'))
      @tg = Telegram::Bot::Client.new(tg_token, logger: @logger)
    end

    @chat_id = opts.fetch(:tg_chat_id, ENV.fetch('ALERT_MANAGER_TO_TG'))
  end

  # {
  #   "groupKey": "{}:{alertname=\"testnet-fork\"}",
  #   "version": "4",
  #   "externalURL": "http://47-245-29-58:8132",
  #   "commonAnnotations": {
  #     "summary": "Fork last for more than 20 minutes at testnet"
  #   },
  #   "commonLabels": {
  #     "severity": "warning",
  #     "monitor": "ckb",
  #     "alertname": "testnet-fork"
  #   },
  #   "groupLabels": {
  #     "alertname": "testnet-fork"
  #   },
  #   "alerts": [
  #     {
  #       "generatorURL": "http://47-245-29-58:8131/graph?g0.expr=count%28count%28Node_Get_LastBlockInfo%7BNodePort%3D%228121%22%2Cjob%3D~%22ckb%22%7D%29+BY+%28last_block_hash%2C+last_blocknumber%29%29+%3E+1&g0.tab=1",
  #       "endsAt": "0001-01-01T00:00:00Z",
  #       "startsAt": "2019-07-25T21:20:21.917968698+08:00",
  #       "annotations": {
  #         "summary": "Fork last for more than 20 minutes at testnet"
  #       },
  #       "labels": {
  #         "severity": "warning",
  #         "monitor": "ckb",
  #         "alertname": "testnet-fork"
  #       },
  #       "status": "firing"
  #     }
  #   ],
  #   "status": "firing",
  #   "receiver": "default-mails"
  # }
  def on_event(payload)
    alerts = payload['alerts'] || []

    alerts.each do |alert|
      labels = alert['labels'].to_a.map {|(k, v)| "#{CGI.escapeHTML(k)}=#{CGI.escapeHTML(v)}" }.join("\n")

      text = <<-HTML.gsub(/^ {8}/, '')
        <b>#{alert['status']}</b>: #{CGI.escapeHTML(alert['annotations']['summary'])}

        #{labels}
      HTML

      tg.api.send_message(
        chat_id: chat_id,
        parse_mode: 'HTML',
        text: text
      )
    end

    'ok'
  end
end

