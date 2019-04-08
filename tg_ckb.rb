require 'telegram/bot'
require 'dotenv/load'
require 'logger'
require 'cgi'

token = ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN')

def on_message(bot, message)
  case message.text
  when '/start'
    bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
  when '/stop'
    bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}")
  end
end

Telegram::Bot::Client.run(token, logger: Logger.new(STDOUT)) do |bot|
  bot.listen do |message|
    on_message(bot, message)
  end
end
