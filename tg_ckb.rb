require 'telegram/bot'
require 'dotenv/load'
require 'logger'
require_relative 'github_bot'

token = ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN')
ALLOWED_GROUPS = ENV['TELEGRAM_CKB_GROUPS'].to_s.split(',').map(&:to_i)

def on_message(bot, message)
  return unless ALLOWED_GROUPS.include?(message.chat.id)

  case message.text
  when '/start'
    bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
  when '/stop'
    bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}")
  when %r{\A/issue\s}
    title, body = message.text.split(/[\r\n]+/, 2)
    title = title.split(/\s/, 2).last
    github_bot = GithubBot.new
    github_bot.authenticate_installation('nervosnetwork')
    issue = github_bot.installation_client.create_issue('nervosnetwork/ckb-internal', title, body)

    bot.api.send_message(
      chat_id: message.chat.id,
      parse_mode: 'Markdown',
      text: render_issue(issue(repo, number))
    )
  when %r{^#(\d+)}
    repo = 'nervosnetwork/ckb-internal'
    number = $1

    bot.api.send_message(
      chat_id: message.chat.id,
      parse_mode: 'Markdown',
      text: render_issue(issue(repo, number))
    )
  when %r{^https://github.com/(nervosnetwork/[^/]+-internal)/issues/(\d+)}
    repo = $1
    number = $2

    bot.api.send_message(
      chat_id: message.chat.id,
      parse_mode: 'Markdown',
      text: render_issue(issue(repo, number))
    )
  end
end

def issue(repo, number)
  github_bot = GithubBot.new
  github_bot.authenticate_installation('nervosnetwork')
  github_bot.installation_client.issue(repo, number)
end

def render_issue(bot, issue)
  <<-MD
[\##{issue['number']}](#{issue['html_url']}) #{issue['title']}

#{issue['body']}

Assignees: #{issue['assignees'].map {|u| u['login']}.join(', ')}
Labels: #{issue['labels'].map {|l| l['name']}.join(', ')}
  MD
end

Telegram::Bot::Client.run(token, logger: Logger.new(STDOUT)) do |bot|
  bot.listen do |message|
    on_message(bot, message)
  end
end
