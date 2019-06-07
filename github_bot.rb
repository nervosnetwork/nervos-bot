# frozen_string_literal: true

require 'octokit'
require 'logger'
require 'jwt'
require 'time'
require 'openssl'
require 'base64'
require 'uri'
require 'telegram/bot'

class GithubBot
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']
  PREVIEW_HEADER = { accept: 'application/vnd.github.machine-man-preview+json' }.freeze

  attr_reader :logger
  attr_reader :brain
  attr_reader :app_client
  attr_accessor :installation_client

  # github_bot = GithubBot.new
  # github_bot.authenticate_installation('nervosnetwork')
  # github_bot.installation_client.create_issue('nervosnetwork/nervos-bot', 'test', 'client')
  def initialize(brain, opts = nil)
    opts ||= {}
    @logger = opts.fetch(:logger, Logger.new(STDOUT))
    if opts.include?(:tg)
      @tg = opts[:tg]
    else
      tg_token = opts.fetch(:tg_access_token, ENV.fetch('TELEGRAM_CKB_ACCESS_TOKEN'))
      @tg = Telegram::Bot::Client.new(tg_token, logger: @logger)
    end

    @brain = brain

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
      installation_id = app_client.find_organization_installation(org_or_installation_id, PREVIEW_HEADER.dup)[:id]
    end

    installation_token = app_client.create_app_installation_access_token(
      installation_id,
      PREVIEW_HEADER.dup
    )[:token]
    @installation_client = Octokit::Client.new(bearer_token: installation_token)
    @installation_client.auto_paginate = true
  end

  def on_event(event_type, payload)
    method_name = "on_#{event_type}"
    send method_name, payload if respond_to?(method_name)
  end

  def on_pull_request(payload)
    try_add_base_branch_in_pull_request_title(payload)
    try_hold_pull_request(payload)
    try_add_breaking_change_label_to_pull_request(payload)

    case payload['action']
    when 'opened'
      assign_reviewer(payload)
      try_add_hotfix_label(payload)
      create_pr_mirror(payload)
    when 'closed'
      notify_pull_requests_merged(payload) if payload['pull_request']['merged']
      delete_pr_mirror(payload)
    else
      create_pr_mirror(payload)
    end
  end

  def on_issue_comment(payload)
    case payload['action']
    when 'created'
      case payload['comment']['body'].to_s
      when /^@nervos-bot(?:-user)?\s+([^\s]+)\s*(.*)/
        command = Regexp.last_match(1)
        args = Regexp.last_match(2).strip
        case command
        when 'ci-status'
          ci_status(payload, args)
        when 'ci'
          ci_status(payload, args.split.last) if args.split.first == 'status'
        when 'give'
          give_me_five(payload) if args.strip.split == %w[me five]
        when 'try'
          try_integration(payload) if args.strip.split == %w[integration]
        end
      end
    end
  end

  def on_check_run(payload)
    return unless payload['check_run']['name'].include?('Travis CI - ')
    return unless brain.ci_sync_projects.include?(payload['repository']['name'])

    request = dup_check_run_from_travis(payload['check_run'])
    post_check_run(payload['repository']['full_name'], request)
  end

  def on_check_suite(payload)
    return unless payload['action'] == 'rerequested'

    head_sha = payload['check_suite']['head_commit']['id']
    repo = payload['repository']['full_name']
    accept = 'application/vnd.github.antiope-preview+json'

    installation_client.get("/repos/#{repo}/commits/#{head_sha}/check-runs", accept: accept)['check_runs'].each do |check|
      if check['name'].include?('Travis CI - ')
        request = dup_check_run_from_travis(check)
        post_check_run(payload['repository']['full_name'], request)
      end
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

    brain.pull_requests_to_tg.fetch(payload['repository']['name'], []).each do |chat_id|
      @tg.api.send_message(
        chat_id: chat_id,
        parse_mode: 'HTML',
        text: <<-HTML.gsub(/^ {10}/, '')
          <b>PR Merged</b>: <a href="#{pull_request['html_url']}">\##{pull_request['number']}</a> #{CGI.escapeHTML(pull_request['title'])}
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
    return if base == default_branch

    base_tag = "[ᚬ#{base}]"
    title = payload['pull_request']['title']
    return if title.include?(base_tag)

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

    from_title = if payload['action'] == 'opened'
                   ''
                 else
                   payload['changes']['title']['from']
                 end
    from_hold = from_title.include?('HOLD') || from_title.include?('✋') || from_title.include?('WIP')
    to_title = payload['pull_request']['title']
    to_hold = to_title.include?('HOLD') || to_title.include?('✋') || to_title.include?('WIP')

    # HOLD
    if !from_hold && to_hold
      installation_client.create_pull_request_review(
        payload['repository']['id'],
        payload['pull_request']['number'],
        body: "Hold as requested by @#{payload['sender']['login']}.",
        event: 'REQUEST_CHANGES'
      )
    end

    # UNHOLD
    if from_hold && !to_hold
      installation_client.pull_request_reviews(
        payload['repository']['id'],
        payload['pull_request']['number']
      ).each do |review|
        next unless review['user']['login'] == 'nervos-bot[bot]' && review['state'] == 'CHANGES_REQUESTED'

        installation_client.dismiss_pull_request_review(
          payload['repository']['id'],
          payload['pull_request']['number'],
          review['id'],
          "Unhold as requested by @#{payload['sender']['login']}."
        )
      end
    end
  end

  def ci_status(payload, sha)
    return unless can_write(payload['comment']['user']['login'], payload['repository']['id'])

    repo = payload['repository']['full_name']

    installation_client.create_issue_comment_reaction(
      payload['repository']['id'],
      payload['comment']['id'],
      '+1'
    )

    request = {
      accept: 'application/vnd.github.antiope-preview+json',
      status: 'completed',
      conclusion: 'success',
      head_sha: sha,
      details_url: payload['comment']['html_url'],
      name: 'Nervos CI',
      completed_at: Time.now.utc.iso8601,
      output: {
        title: 'CI passed via devtools/ci/local.sh',
        summary: "@#{payload['comment']['user']['login']} ran CI locally and submitted the status via #{payload['comment']['html_url']}"
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
    request[:output][:title] = 'Integration passed via devtools/ci/local.sh'

    if body.include?('Integration: success')
      request[:conclusion] = 'success'
      post_check_run(repo, request)
    elsif body.include?('Integration: failure')
      request[:conclusion] = 'failure'
      post_check_run(repo, request)
    end
  end

  def give_me_five(payload)
    return unless can_write(payload['comment']['user']['login'], payload['repository']['id'])

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
    %w[admin write].include?(permission_level['permission'])
  end

  def post_check_run(repo, request)
    request = request.dup
    head_sha = request[:head_sha]
    accept = 'application/vnd.github.antiope-preview+json'
    installation_client.get("/repos/#{repo}/commits/#{request[:head_sha]}/check-runs", accept: accept)['check_runs'].each do |check|
      if check['name'] == request[:name] && check['app']['name'] == 'Nervos Bot' && check['head_sha'] == head_sha
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
    users = brain.reviewers[payload['repository']['name']]
    return unless users && !users.empty?

    sender = payload['pull_request']['user']['login']
    return if sender == users[0] && users.size == 1

    if sender == users[0]
      users.shift
      reviewer = users[0]
      users.rotate!
      users.unshift sender
    else
      reviewer = users[0]
      users.rotate!
    end

    repo = payload['repository']['id']
    number = payload['pull_request']['number']

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
      name: 'Nervos CI',
      completed_at: check_run['completed_at'],
      output: {
        title: "#{check_run['output']['title']} via Travis",
        summary: check_run['output']['summary']
      }
    }
    request.delete(:conclusion) if request[:conclusion].nil?
    request.delete(:completed_at) if request[:completed_at].nil?
    if check_run['name'].include?('Branch')
      request[:name] = 'Nervos Integration'
    end

    request
  end

  def delete_pr_mirror(payload)
    return unless brain.ci_fork_projects.include?(payload['repository']['name'])
    return if payload['pull_request']['head']['repo']['id'] == payload['pull_request']['base']['repo']['id']

    repo = payload['repository']['id']
    number = payload['pull_request']['number']
    ref = "heads/pr-mirror/#{number}"
    begin
      installation_client.delete_ref(repo, ref)
    rescue Octokit::UnprocessableEntity
      # ignore
    end
  end

  def create_pr_mirror(payload)
    return unless brain.ci_fork_projects.include?(payload['repository']['name'])
    return if payload['pull_request']['head']['repo']['id'] == payload['pull_request']['base']['repo']['id']
    return unless can_write(payload['pull_request']['user']['login'], payload['repository']['id'])

    repo = payload['repository']['id']
    number = payload['pull_request']['number']
    ref = "heads/pr-mirror/#{number}"
    sha = payload['pull_request']['head']['sha']

    begin
      installation_client.create_ref(repo, ref, sha)
    rescue Octokit::UnprocessableEntity => e
      if e.message.include?('Reference already exists')
        existing_ref = installation_client.ref(repo, ref)
        if existing_ref['object']['sha'] != sha
          installation_client.update_ref(repo, ref, sha, true)
        end
      else
        raise
      end
    end
  end

  def try_integration(payload)
    return unless brain.ci_fork_projects.include?(payload['repository']['name'])
    return unless can_write(payload['comment']['user']['login'], payload['repository']['id'])

    installation_client.create_issue_comment_reaction(
      payload['repository']['id'],
      payload['comment']['id'],
      'hooray'
    )

    create_pr_mirror(
      'pull_request' => installation_client.pull_request(payload['repository']['id'], payload['issue']['number']),
      'repository' => payload['repository']
    )
  end
end
