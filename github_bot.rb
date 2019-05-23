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
    @ci_sync_projects = ENV['GITHUB_CI_SYNC'].to_s.split(',')

    @pull_requests_to_tg = {}
    @reviewers = {}
    ENV.each_pair do |k, v|
      case k
      when /\AGITHUB_PULL_REQUESTS_TO_TG_(_?\d+)\z/
        chat_id = $1.gsub(/_/, '-').to_i
        v.split(',').each do |project|
          @pull_requests_to_tg[project] ||= []
          @pull_requests_to_tg[project] << chat_id
        end
      when /\AGITHUB_REVIEWERS/
        project, users = v.split(',', 2)
        @reviewers[project] = users.split(',')
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
    @installation_client.auto_paginate = true
  end

  def on_event(event_type, payload)
    method_name = "on_#{event_type}"
    if respond_to?(method_name) then
      send method_name, payload
    end
  end

  def on_pull_request(payload)
    try_add_base_branch_in_pull_request_title(payload)
    try_hold_pull_request(payload)
    try_add_breaking_change_label_to_pull_request(payload)
    case payload['action']
    when 'opened'
      assign_reviewer(payload)
      try_add_hotfix_label(payload)
    when 'closed'
      if payload['pull_request']['merged']
        notify_pull_requests_merged(payload)
      end
    end
  end

  def on_issue_comment(payload)
    case payload['action']
    when 'created'
      case payload['comment']['body'].to_s
      when /^@nervos-bot(?:-user)?\s+([^\s]+)\s*(.*)/
        command = $1
        args = $2.strip
        case command
        when 'ci-status'
          ci_status(payload, args)
        when 'ci'
          if args.split.first == 'status'
            ci_status(payload, args.split.last)
          end
        when 'give'
          if args.strip.split == %w(me five)
            give_me_five(payload)
          end
        end
      end
    end
  end

  def on_check_run(payload)
    unless payload['check_run']['name'].include?('Travis CI - ')
      return
    end
    unless @ci_sync_projects.include?(payload['repository']['name'])
      return
    end

    request = dup_check_run_from_travis(payload['check_run'])
    post_check_run(payload['repository']['full_name'], request)
  end

  def on_check_suite(payload)
    return unless payload['action'] == 'rerequested'
    head_sha = payload['check_suite']['head_commit']['id']

    request = dup_check_run_from_travis(payload['check_run'])
    post_check_run(payload['repository']['full_name'], request)
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

  def try_add_base_branch_in_pull_request_title(payload)
    unless payload['action'] == 'opened' || (payload['changes'] && (payload['changes']['title'] || payload['changes']['base']))
      return
    end

    default_branch = payload['repository']['default_branch']
    base = payload['pull_request']['base']['ref']
    if base == default_branch
      return
    end

    base_tag = "[ᚬ#{base}]"
    title = payload['pull_request']['title']
    if title.include?(base_tag)
      return
    end

    new_title = [base_tag, title].join(' ')
    installation_client.update_pull_request(
      payload['repository']['id'], 
      payload['pull_request']['number'], 
      title: new_title
    )
  end

  def try_hold_pull_request(payload)
    unless payload['action'] == 'opened' || (payload['changes'] && payload['changes']['title'])
      return
    end

    from_title = if payload['action'] == 'opened' then
                   ''
                 else
                   payload['changes']['title']['from']
                 end
    from_hold = from_title.include?('HOLD') || from_title.include?('✋') || from_title.include?('WIP')
    to_title = payload['pull_request']['title']
    to_hold = to_title.include?('HOLD') || to_title.include?('✋') || to_title.include?('WIP')

    # HOLD
    if !from_hold && to_hold then
      installation_client.create_pull_request_review(
        payload['repository']['id'],
        payload['pull_request']['number'],
        body: "Hold as requested by @#{payload['sender']['login']}.",
        event: 'REQUEST_CHANGES'
      )
    end

    # UNHOLD
    if from_hold && !to_hold then
      installation_client.pull_request_reviews(
        payload['repository']['id'],
        payload['pull_request']['number']
      ).each do |review|
        if review['user']['login'] == 'nervos-bot[bot]' && review['state'] == 'CHANGES_REQUESTED'
          installation_client.dismiss_pull_request_review(
            payload['repository']['id'],
            payload['pull_request']['number'],
            review['id'],
            "Unhold as requested by @#{payload['sender']['login']}."
          )
        end
      end
    end
  end

  def ci_status(payload, sha)
    return if !can_write(payload['comment']['user']['login'], payload['repository']['id'])

    repo = payload['repository']['full_name']

    installation_client.create_issue_comment_reaction(
      payload['repository']['id'],
      payload['comment']['id'],
      '+1'
    )

    request = {
      accept: 'application/vnd.github.antiope-preview+json',
      status: "completed",
      conclusion: "success",
      head_sha: sha,
      details_url: payload['comment']['html_url'],
      name: "Nervos CI",
      completed_at: Time.now.utc.iso8601,
      output: {
        title: "CI passed via devtools/ci/local.sh",
        summary: "@#{payload['comment']['user']['login']} ran CI locally and submitted the status via #{payload['comment']['html_url']}",
      }
    }
    body = payload['comment']['body'].to_s
    if body.include?('CI: success')
      request[:conclusion] = 'success'
      post_check_run(repo, request)
    elsif body.include?('CI: failure')
      request[:conclusion] = 'failure'
      post_check_run(repo, request)
    end

    request[:name] = 'Nervos Integration'
    request[:output][:title] = "Integration passed via devtools/ci/local.sh"

    if body.include?('Integration: success')
      request[:conclusion] = 'success'
      post_check_run(repo, request)
    elsif body.include?('Integration: failure')
      request[:conclusion] = 'failure'
      post_check_run(repo, request)
    end
  end

  def give_me_five(payload)
    return if !can_write(payload['comment']['user']['login'], payload['repository']['id'])

    installation_client.create_issue_comment_reaction(
      payload['repository']['id'],
      payload['comment']['id'],
      'hooray'
    )
    installation_client.create_pull_request_review(
      payload['repository']['id'],
      payload['issue']['number'],
      body: "🚢 requested by @#{payload['comment']['user']['login']} in #{payload['comment']['html_url']}",
      event: 'APPROVE'
    )
  end

  def can_write(user, repository)
    permission_level = installation_client.permission_level(repository, user)
    return %w(admin write).include?(permission_level['permission'])
  end

  def post_check_run(repo, request)
    request = request.dup
    head_sha = request[:head_sha]
    accept = 'application/vnd.github.antiope-preview+json'
    installation_client.get("/repos/#{repo}/commits/#{request[:head_sha]}/check-runs", accept: accept)['check_runs'].each do |check|
      if check['name'] == request[:name] && check['app']['name'] == 'Nervos Bot' && check['head_sha'] == head_sha then
        request.delete(:head_sha)
        installation_client.patch("/repos/#{repo}/check-runs/#{check['id']}", request.dup)
      end
    end
    if request[:head_sha]
      installation_client.post("/repos/#{repo}/check-runs", request)
    end
  end

  def try_add_breaking_change_label_to_pull_request(payload)
    body = payload['pull_request']['body'].to_s
    if body.downcase.include?('breaking change')
      installation_client.add_labels_to_an_issue(payload['repository']['id'], payload['pull_request']['number'], ['breaking change'])
    end
  end

  def assign_reviewer(payload)
    users = @reviewers[payload['repository']['name']]
    return unless users
    users.delete(payload['pull_request']['user']['login'])
    return if users.empty?

    repo = payload['repository']['id']
    number = payload['pull_request']['number']

    reviewer = users.sample
    installation_client.add_assignees(repo, number, [reviewer])
    installation_client.add_comment(repo, number, "@#{reviewer} is assigned as the chief reviewer")
  end

  def dup_check_run_from_travis(check_run)
    accept = 'application/vnd.github.antiope-preview+json'
    request = {
      accept: accept,
      status: check_run['status'],
      conclusion: check_run['conclusion'],
      head_sha: check_run['head_sha'],
      details_url: check_run['details_url'],
      name: "Nervos CI",
      completed_at: check_run['completed_at'],
      output: {
        title: "#{check_run['output']['title']} via Travis",
        summary: check_run['output']['summary']
      }
    }
    request.delete(:conclusion) if request[:conclusion].nil?
    request.delete(:completed_at) if request[:completed_at].nil?
    if check_run['name'].include?('Branch')
      request[:name] = "Nervos Integration"
    end

    request
  end
end
