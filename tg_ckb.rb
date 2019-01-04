require 'telegram/bot'
require 'dotenv/load'
require 'logger'
require_relative 'github_bot'

ALLOWED_GROUPS = ENV['TELEGRAM_CKB_GROUPS'].to_s.split(',').map(&:to_i)
ORG = 'nervosnetwork'
REPO = 'nervosnetwork/ckb-internal'
token = ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN')

HELP = <<-TEXT
/issue - show the issue: /issue number
/newissue - create an issue: /newissue title
TEXT

def on_message(bot, message)
  return unless ALLOWED_GROUPS.include?(message.chat.id)

  case message.text
  when '/start'
    bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}")
  when '/stop'
    bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}")
  when '/help'
    bot.api.send_message(chat_id: message.chat.id, text: HELP)
  when %r{\A/newissue\s}
    title, body = message.text.split(/[\r\n]+/, 2)
    title = title.split(/\s/, 2).last
    github_bot = GithubBot.new
    github_bot.authenticate_installation(ORG)
    issue = github_bot.installation_client.create_issue(REPO, title, body.to_s)

    bot.api.send_message(
      chat_id: message.chat.id,
      parse_mode: 'Markdown',
      text: render_issue(issue, false)
    )
  when %r{\A/issue\s+#?(\d+)}
    number = $1

    bot.api.send_message(
      chat_id: message.chat.id,
      parse_mode: 'Markdown',
      text: render_issue(get_issue(REPO, number))
    )
  end
end

def get_issue(repo, number)
  github_bot = GithubBot.new
  github_bot.authenticate_installation(ORG)
  github_bot.installation_client.issue(repo, number)
end

def render_issue(issue, include_details = true)
  title = "[\##{issue['number']}](#{issue['html_url']}) #{issue['title']}"
  return title unless include_details

  <<-MD
#{title}

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
