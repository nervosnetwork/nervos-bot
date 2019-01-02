require 'logger'

class GithubBot
  attr_reader :logger
  attr_reader :api_client
  attr_reader :installation_client

  def initialize(opts)
    @api_client = opts[:api_client]
    @installation_client = opts[:installation_client]
    @logger = opts.fetch(:logger, Logger.new(STDOUT))
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
