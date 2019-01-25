require 'telegram/bot'
require 'dotenv/load'
require 'logger'
require 'cgi'
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
      parse_mode: 'HTML',
      text: render_issue(issue, false)
    )
  when %r{\A/issue\s+#?(\d+)}
    number = $1

    bot.api.send_message(
      chat_id: message.chat.id,
      parse_mode: 'HTML',
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
  title = "<a href=\"#{issue['html_url']}\">\##{issue['number']}</a> <b>#{CGI::escapeHTML(issue['title'])}</b>"
  return title unless include_details

  <<-HTML
#{title}

#{CGI::escapeHTML(issue['body'])}

<b>Assignees</b>: #{issue['assignees'].map {|u| u['login']}.join(', ')}
<b>Labels</b>: #{issue['labels'].map {|l| l['name']}.join(', ')}
  HTML
end

Telegram::Bot::Client.run(token, logger: Logger.new(STDOUT)) do |bot|
  bot.listen do |message|
    on_message(bot, message)
  end
end
