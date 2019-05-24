test:
	bundle exec ruby -I. -e 'ARGV.each { |f| require f }' *_test.rb
