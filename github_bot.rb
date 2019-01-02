require 'octokit'
require 'logger'
require 'jwt'
require 'time'
require 'openssl'

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

    payload = {
      iat: Time.now.to_i,
      exp: Time.now.to_i + (10 * 60),
      iss: opts.fetch(:app_identifier, APP_IDENTIFIER)
    }
    private_key = opts[:private_key]
    if private_key.nil?
      private_key = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))
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

  def on_issue_comment(payload)
    case payload['action']
    when 'created'
      case payload['comment']['body']
      when /^@nervos-bot\s+publish/
        publish_issue(payload)
      end
    end
  end

  def publish_issue(payload)
    repository = payload['repository']
    repository_id = repository['id']
    issue = payload['issue']
    comment = payload['comment']

    return unless issue['state'] == 'open'

    match = /(.*)-internal/.match(repository['full_name'])
    return unless match

    to_project = match[1]

    transfered = installation_client.create_issue(
      to_project,
      issue['title'],
      issue['body'],
      assignees: issue['assignees'].map {|u| u['login']},
      labels: issue['labels'].map {|l| l['name']}.join(","),
      accept: 'application/vnd.github.symmetra-preview+json'
    )

    logger.info "publish #{repository['full_name']}\##{issue['number']} as #{to_project}\##{transfered['number']}"

    installation_client.add_comment(
      repository_id,
      issue['number'],
      "@#{comment['user']['login']} published as #{transfered['html_url']}"
    )
    installation_client.close_issue(
      repository_id,
      issue['number']
    )
  end
end
