require 'octokit'
require 'logger'
require 'jwt'
require 'time'
require 'openssl'
require 'base64'
require 'telegram/bot'

class GithubBot
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']
  PREVIEW_HEADER = { accept: 'application/vnd.github.machine-man-preview+json' }

  attr_reader :logger
  attr_reader :app_client
  attr_reader :installation_client

  # github_bot = GithubBot.new
  # github_bot.authenticate_installation('nervosnetwork')
  # github_bot.installation_client.create_issue('nervosnetwork/nervos-bot', 'test', 'client')
  def initialize(opts = nil)
    opts ||= {}
    @logger = opts.fetch(:logger, Logger.new(STDOUT))
    tg_token = opts.fetch('TELEGRAM_CKB_ACCESS_TOKEN', ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN'))
    @tg = Telegram::Bot::Client.new(tg_token, logger: @logger)

    @issues_to_column = {}
    @pull_requests_to_column = {}
    @pull_requests_to_tg = {}
    ENV.each_pair do |k, v|
      case k
      when /\AGITHUB_ISSUES_TO_COLUMN_(\d+)\z/
        col_id = $1.to_i
        v.split(',').each do |project|
          @issues_to_column[project] ||= []
          @issues_to_column[project] << col_id
        end
      when /\AGITHUB_PULL_REQUESTS_TO_COLUMN_(\d+)\z/
        col_id = $1.to_i
        v.split(',').each do |project|
          @pull_requests_to_column[project] ||= []
          @pull_requests_to_column[project] << col_id
        end
      when /\AGITHUB_PULL_REQUESTS_TO_TG_(_?\d+)\z/
        chat_id = $1.gsub(/_/, '-').to_i
        v.split(',').each do |project|
          @pull_requests_to_tg[project] ||= []
          @pull_requests_to_tg[project] << chat_id
        end
      end
    end

    payload = {
      iat: Time.now.to_i,
      exp: Time.now.to_i + (10 * 60),
      iss: opts.fetch(:app_identifier, APP_IDENTIFIER)
    }
    private_key = opts[:private_key]
    if private_key.nil?
      lines = ['-----BEGIN RSA PRIVATE KEY-----'].concat(
        ENV['GITHUB_PRIVATE_KEY'].chars.each_slice(64).map(&:join)
      )
      lines.push('-----END RSA PRIVATE KEY-----')
      private_key = OpenSSL::PKey::RSA.new(lines.join("\n"))
    end
    jwt = JWT.encode(payload, private_key, 'RS256')
    @app_client = Octokit::Client.new(bearer_token: jwt)
  end

  def authenticate_installation(org_or_installation_id)
    if org_or_installation_id.is_a?(Integer)
      installation_id = org_or_installation_id
    else
      installation_id = app_client.find_organization_installation(org_or_installation_id, PREVIEW_HEADER)[:id]
    end

    installation_token = app_client.create_app_installation_access_token(
      installation_id, 
      PREVIEW_HEADER
    )[:token]
    @installation_client = Octokit::Client.new(bearer_token: installation_token)
  end

  def on_event(event_type, payload)
    method_name = "on_#{event_type}"
    if respond_to?(method_name) then
      send method_name, payload
    end
  end

  def on_issues(payload)
    case payload['action']
    when 'opened'
      begin
        add_issues_to_column(payload)
      rescue Octokit::UnprocessableEntity => e
        unless e.response_body.include?('Project already has the associated issue')
          raise e
        end
      end
    end
  end

  def on_pull_request(payload)
    case payload['action']
    when 'opened'
      try_add_hotfix_label(payload)
      begin
        add_pull_requests_to_column(payload)
      rescue Octokit::UnprocessableEntity => e
        unless e.response_body.include?('Project already has the associated issue')
          raise e
        end
      end
    when 'closed'
      if payload['pull_request']['merged']
        notify_pull_requests_merged(payload)
      end
    end
  end

  def add_issues_to_column(payload)
    @issues_to_column.fetch(payload['repository']['name'], []).each do |col_id|
      installation_client.create_project_card(col_id, content_id: payload['issue']['id'], content_type: 'Issue')
    end
  end

  def add_pull_requests_to_column(payload)
    @pull_requests_to_column.fetch(payload['repository']['name'], []).each do |col_id|
      installation_client.create_project_card(col_id, content_id: payload['pull_request']['id'], content_type: 'PullRequest')
    end
  end

  def try_add_hotfix_label(payload)
    repository = payload['repository']
    repository_id = repository['id']
    pull_request = payload['pull_request']
    if pull_request['base']['ref'].start_with?('rc/')
      installation_client.add_labels_to_an_issue(repository_id, pull_request['number'], ['hotfix'])
    end
  end

  def notify_pull_requests_merged(payload)
    pull_request = payload['pull_request']
    return if pull_request['title'].include?('chore(deps): ')

    @pull_requests_to_tg.fetch(payload['repository']['name'], []).each do |chat_id|
      @tg.api.send_message(
        chat_id: chat_id,
        parse_mode: 'HTML',
        text: <<-HTML.gsub(/^ {10}/, '')
          <b>PR Merged</b>: <a href="#{pull_request['html_url']}">\##{pull_request['number']}</a> #{CGI::escapeHTML(pull_request['title'])}
        HTML
      )
    end
  end
end
