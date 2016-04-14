#!/usr/bin/env ruby
#
# Opsgenie handler which creates and closes alerts. Based on the pagerduty
# handler.
#

require 'em-http-request'
require 'json'
require 'net/https'
require 'sensu-handler'
require 'sensu/extension'
require 'timeout'
require 'uri'

module Sensu::Extension
  class Opsgenie < Handler
    def name
      'opsgenie'
    end

    def description
      'Passes events to OpsGenie'
    end

    def definition
      {
        type: 'extension',
        name: 'opsgenie',
      }
    end

    def logger
      Sensu::Logger.get
    end

    def initialize
      super

      @api_url = 'https://api.opsgenie.com'

      @request_options = {
        :connect_timeout => 10,
        :inactivity_timeout => 10,

        :ssl => {
          :verify_peer => false,
        },

        :head => {
          'Content-Type' => 'application/json',
        },
      }
    end

    def run(event)
      event = JSON.parse(event) if event.class == String

      @config = @settings[:opsgenie]
      # allow @config to be changed by the check
      if event['check']['opsgenie']
        @config.merge!(event['check']['opsgenie'])
      end
      description = event['notification'] || [event['client']['name'],
                                              event['check']['name'],
                                              event['check']['output'].chomp].join(' : ')

      if event['client']['name'].start_with? 'prod'

        response = case event['action']
                   when 'create'
                     create_alert(event, description)
                   when 'resolve'
                     close_alert(event)
                   else
                     @logger.info("opsgenie: non-action event: #{event}")
                   end

        msg_event = "#{event['action']} '#{event_alias(event)}'"

        # Failed connection such as timeout or bad DNS
        response.errback do
          msg = "opsgenie: connection failure: #{msg_event}, error: #{response.error}"
          @logger.error(msg)
          yield msg, 2
        end

        response.callback do |http|

          if http.response_header.status == 200
            msg = "opsgenie: request success: #{msg_event}"
            @logger.debug(msg)
            yield msg, 0
          else
            msg = "opsgenie: request failure: #{msg_event}, " +
                  "code: #{http.response_header.status}, response: #{http.response}"
            @logger.error(msg)
            yield msg, 2
          end

        end
      else
        msg = "opsgenie: avoided handling for host '#{event['client']['name']}' due to test code"
        logger.info(msg)
        yield msg, 0
      end
    end

    def event_alias(event)
      event['client']['name'] + '/' + event['check']['name']
    end

    def event_status(event)
      event['check']['status']
    end

    def close_alert(event)
      post_to_opsgenie(:close, alias: event_alias(event))
    end

    def event_tags(event)
      event['client']['tags']
    end

    def create_alert(event, description)
      tags = []
      tags << @config['tags'] if @config['tags']
      tags << 'OverwriteQuietHours' if event_status(event) == 2 && @config['overwrite_quiet_hours'] == true
      tags << 'unknown' if event_status(event) >= 3
      tags << 'critical' if event_status(event) == 2
      tags << 'warning' if event_status(event) == 1
      unless event_tags(event).nil?
        event_tags(event).each { |tag, value| tags << "#{tag}_#{value}" }
      end

      recipients = @config['recipients'] if @config['recipients']
      teams = @config['teams'] if @config['teams']

      post_to_opsgenie(action: :create,
                       alias: event_alias(event),
                       message: description,
                       tags: tags.join(','),
                       recipients: recipients,
                       teams: teams)
    end

    def post_to_opsgenie(action = :create, **params)
      params['customerKey'] = @config['customerKey']

      # override source if specified, default is ip
      params['source'] = @config['source'] if @config['source']

      uripath = (action == :create) ? '' : 'close'
      path = "/v1/json/alert/#{uripath}"

      @logger.debug("opsgenie: making request: '#{path}' body: #{params}")

      EventMachine.run do
        EventMachine::HttpRequest.new(@api_url, @request_options).post(
          :path => path, :body => params.to_json)
      end
    end
  end
end
