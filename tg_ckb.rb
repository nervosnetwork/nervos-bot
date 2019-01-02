require 'telegram/bot'
require 'dotenv/load'
require 'logger'
require_relative 'github_bot'

token = ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN')

Telegram::Bot::Client.run(token, logger: Logger.new(STDOUT)) do |bot|
  bot.listen do |message|
    case message.text
    when '/start'
      bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
    when '/stop'
      bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}")
    when %r{^https://github.com/(nervosnetwork/[^/]+-internal)/issues/(\d+)}
      repo = $1
      number = $2

      github_bot = GithubBot.new
      github_bot.authenticate_installation('nervosnetwork')

      issue = github_bot.installation_client.issue(repo, number)

      bot.api.send_message(
        chat_id: message.chat.id,
        parse_mode: 'Markdown',
        text: <<-MD
# #{issue['title']}

#{issue['body']}

Assignees: #{issue['assignees'].map {|u| u['login']}}
Labels: #{issue['labels'].map {|l| l['name']}.join(', ')}
        MD
      )
    end
  end
end
