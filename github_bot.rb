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
      # assign_reviewer(payload)
      try_add_hotfix_label(payload)
      post_dummy_ci_status(payload['repository'], payload['pull_request']['head']['sha'])
    when 'synchronize'
      post_dummy_ci_status(payload['repository'], payload['pull_request']['head']['sha'])
    when 'closed'
      create_issue_to_backport(payload) if payload['pull_request']['merged']
      notify_pull_requests_merged(payload) if payload['pull_request']['merged']
    end
  end

  def on_push(payload)
    unless payload['after'].chars.all? {|c| c == '0'}
      post_dummy_ci_status(payload['repository'], payload['after'])
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
        when 'give'
          give_me_five(payload) if args.strip.split == %w[me five]
        when 'dummy-ci'
          post_dummy_ci_status(payload['repository'], args)
        when 'dummy'
          post_dummy_ci_status(payload['repository'], args.split.last) if args.split.first == 'ci'
        end
      when /^bors:?\s+r[\+=]/
        repository = payload['repository']
        repository_id = repository['id']
        issue = payload['issue']
        installation_client.add_labels_to_an_issue(repository_id, issue['number'], ['s:ready-to-merge'])
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
    return if payload['sender']['login'] == 'nervos-bot[bot]'
    unless payload['action'] == 'opened' || (payload['changes'] && payload['changes']['title'])
      return
    end

    from_title = if payload['action'] == 'opened'
                   ''
                 else
                   (payload['changes']['title']['from'] || "").downcase
                 end
    to_title = payload['pull_request']['title'].downcase
    from_title_words = from_title.scan(/\w+/)
    to_title_words = to_title.scan(/\w+/)

    from_hold = from_title_words.include?('hold') || from_title.include?('✋') || from_title_words.include?('wip')
    to_hold = to_title_words.include?('hold') || to_title.include?('✋') || to_title_words.include?('wip')

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

    return unless brain.backport_projects.include?(payload['repository']['name'])

    default_branch = payload['repository']['default_branch']
    base = payload['pull_request']['base']['ref']
    from_is_fix = from_title.include?('fix:') || from_title.split.include?('fix')
    to_is_fix = to_title.include?('fix:') || to_title.split.include?('fix')
    should_backport = default_branch == base && !from_is_fix && to_is_fix

    if should_backport
      refs = installation_client.refs(payload['repository']['id'], 'heads/rc/').map{|ref| ref['ref'] }
      latest_rc = refs.sort_by{|ref| Gem::Version.new(ref.split('/v').last) }.last
      if latest_rc then
        installation_client.add_labels_to_an_issue(
          payload['repository']['id'],
          payload['pull_request']['number'],
          ["backport rc/#{latest_rc.split('/').last}"]
        )
      end
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

  def post_dummy_ci_status(repository, sha)
    return unless brain.dummy_ci_projects.include?(repository['name'])
    repo = repository['full_name']

    request = {
      accept: 'application/vnd.github.antiope-preview+json',
      status: 'completed',
      conclusion: 'success',
      head_sha: sha,
      name: 'Dummy CI',
      completed_at: Time.now.utc.iso8601,
      output: {
        title: 'CI that does nothing',
        summary: 'This status check is required to enable "Require branches to be up to date before merging"'
      }
    }

    post_check_run(repo, request)
  end

  def create_issue_to_backport(payload)
    pr = payload['pull_request']
    if pr['labels'].any? {|label| label['name'].start_with?('backport ') }
      title = "Backport \##{pr['number']}"
      body = "#{title} `#{pr['labels'].map{|label| label['name']}.join('`, `')}`"
      opts = {}
      if can_write(pr['user']['login'], payload['repository']['id'])
        opts[:assignee] = pr['user']['login']
      end
      installation_client.create_issue(payload['repository']['id'], title, body, opts)
    end
  end
end
