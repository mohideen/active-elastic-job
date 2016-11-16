require "action_dispatch"

module ActiveElasticJob
  module Rack
    # This middleware intercepts requests which are sent by the SQS daemon
    # running in {Amazon Elastic Beanstalk worker environments}[http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/using-features-managing-env-tiers.html].
    # It does this by looking at the +User-Agent+ header.
		# Requesets from the SQS daemon are handled in two alternative cases:
		#
		# (1) the processed SQS message was orignally triggered by a periodic task
		# supported by Elastic Beanstalk's Periodic Task feature
		#
		# (2) the processed SQS message was queued by this gem representing an active job.
		# In this case it verifies the digest which is sent along with a legit SQS
    # message, and passed as an HTTP header in the resulting request.
    # The digest is based on Rails' +secrets.secret_key_base+.
    # Therefore, the application running in the web environment, which generates
    # the digest, and the application running in the worker
    # environment, which verifies the digest, have to use the *same*
    # +secrets.secret_key_base+ setting.
    class SqsMessageConsumer
      USER_AGENT_PREFIX = 'aws-sqsd'.freeze
      DIGEST_HEADER_NAME = 'HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'.freeze
      ORIGIN_HEADER_NAME = 'HTTP_X_AWS_SQSD_ATTR_ORIGIN'.freeze
      CONTENT_TYPE = 'application/json'.freeze
      CONTENT_TYPE_HEADER_NAME = 'Content-Type'.freeze
      OK_RESPONSE_CODE = '200'.freeze
      INSIDE_DOCKER_CONTAINER = `[ -f /proc/1/cgroup ] && cat /proc/1/cgroup` =~ /docker/
      DOCKER_HOST_IP = "172.17.0.1".freeze
			PERIODIC_TASK_PATH = "/periodic_tasks".freeze

      def initialize(app) #:nodoc:
        @app = app
      end

      def call(env) #:nodoc:
        request = ActionDispatch::Request.new env
        if enabled? && aws_sqsd?(request)
          unless request.local? || sent_from_docker_host?(request)
            m = "Accepts only requests from localhost for job processing".freeze
            return ['403', {CONTENT_TYPE_HEADER_NAME => 'text/plain' }, [ m ]]
          end

					if periodic_task?(request)
						execute_periodic_task(request)
						return [
							OK_RESPONSE_CODE ,
							{CONTENT_TYPE_HEADER_NAME => CONTENT_TYPE },
							[ '' ]]
					elsif originates_from_gem?(request)
						begin
							verify!(request)
							job = JSON.load(request.body)
							ActiveJob::Base.execute(job)
						rescue ActiveElasticJob::MessageVerifier::InvalidDigest => e
							return [
								'403',
								{CONTENT_TYPE_HEADER_NAME => 'text/plain' },
								["Incorrect digest! Please, make sure that both environments, worker and web, use the same SECRET_KEY_BASE setting."]]
						end
						return [
							OK_RESPONSE_CODE ,
							{CONTENT_TYPE_HEADER_NAME => CONTENT_TYPE },
							[ '' ]]
					end
				end
        @app.call(env)
      end

      private

      def enabled?
        var = ENV['DISABLE_SQS_CONSUMER'.freeze]
        var == nil || var == 'false'.freeze
      end

      def verify!(request)
        secret_key_base = Rails.application.secrets[:secret_key_base]
        @verifier ||= ActiveElasticJob::MessageVerifier.new(secret_key_base)
        digest = request.headers[DIGEST_HEADER_NAME]
        message = request.body_stream.read
        request.body_stream.rewind
        @verifier.verify!(message, digest)
      end

      def aws_sqsd?(request)
        # we do not match against a Regexp
        # in order to avoid performance penalties.
        # Instead we make a simple string comparison.
        # Benchmark runs showed an performance increase of
        # up to 40%
        current_user_agent = request.headers['User-Agent'.freeze]
        return (current_user_agent.present? &&
          current_user_agent.size >= USER_AGENT_PREFIX.size &&
          current_user_agent[0..(USER_AGENT_PREFIX.size - 1)] == USER_AGENT_PREFIX)
      end

			def periodic_task?(request)
				!request.fullpath.nil? && request.fullpath[0..(PERIODIC_TASK_PATH.size - 1)] == PERIODIC_TASK_PATH
			end

			def execute_periodic_task(request)
				job_name = request.headers['X-Aws-Sqsd-Taskname']
				job = job_name.constantize.new
				job.perform_now
			end

      def originates_from_gem?(request)
        if request.headers[ORIGIN_HEADER_NAME] == ActiveElasticJob::ACRONYM
          return true
        elsif request.headers[DIGEST_HEADER_NAME] != nil
          return true
        else
          return false
        end
      end

      def sent_from_docker_host?(request)
        INSIDE_DOCKER_CONTAINER && request.remote_ip == DOCKER_HOST_IP
      end
    end
  end
end
