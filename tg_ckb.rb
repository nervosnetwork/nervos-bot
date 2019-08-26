require 'telegram/bot'
require 'dotenv/load'
require 'logger'
require 'cgi'

token = ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN')

def on_message(bot, message)
  from = message.from || {}

  case message.text
  when '/start'
    greeting = ['Hello', from.first_name].compact.join(', ')
    bot.api.send_message(chat_id: message.chat.id, text: greeting)
  when '/stop'
    bye = ['Bye', from.first_name].compact.join(', ')
    bot.api.send_message(chat_id: message.chat.id, text: bye)
  when '/chatid'
    bot.api.send_message(chat_id: message.chat.id, text: "The chat id is #{message.chat.id}")
  end
end

Telegram::Bot::Client.run(token, logger: Logger.new(STDOUT)) do |bot|
  bot.listen do |message|
    on_message(bot, message)
  end
end
