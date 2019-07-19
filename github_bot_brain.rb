# frozen_string_literal: true

class GithubBotBrain
  attr_accessor :dummy_ci_projects
  attr_accessor :pull_requests_to_tg
  attr_accessor :reviewers

  def initialize
    @dummy_ci_projects = ENV['GITHUB_DUMMY_CI_PROJECTS'].to_s.split(',')

    @pull_requests_to_tg = {}
    @reviewers = {}
    ENV.each_pair do |k, v|
      case k
      when /\AGITHUB_PULL_REQUESTS_TO_TG_(_?\d+)\z/
        chat_id = Regexp.last_match(1).gsub(/_/, '-').to_i
        v.split(',').each do |project|
          @pull_requests_to_tg[project] ||= []
          @pull_requests_to_tg[project] << chat_id
        end
      when /\AGITHUB_REVIEWERS/
        project, users = v.split(',', 2)
        @reviewers[project] = users.split(',').shuffle
      end
    end
  end
end
