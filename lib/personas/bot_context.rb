# frozen_string_literal: true

module DiscourseAi
  module Personas
    class BotContext
      attr_accessor :messages,
                    :topic_id,
                    :post_id,
                    :private_message,
                    :custom_instructions,
                    :user,
                    :skip_tool_details,
                    :participants,
                    :chosen_tools,
                    :message_id,
                    :channel_id,
                    :context_post_ids,
                    :feature_name,
                    :resource_url,
                    :cancel_manager

      def initialize(
        post: nil,
        participants: nil,
        user: nil,
        skip_tool_details: nil,
        messages: [],
        custom_instructions: nil,
        site_url: nil,
        site_title: nil,
        site_description: nil,
        time: nil,
        message_id: nil,
        channel_id: nil,
        context_post_ids: nil,
        feature_name: "bot",
        resource_url: nil,
        cancel_manager: nil
      )
        @participants = participants
        @user = user
        @skip_tool_details = skip_tool_details
        @messages = messages
        @custom_instructions = custom_instructions

        @message_id = message_id
        @channel_id = channel_id
        @context_post_ids = context_post_ids

        @site_url = site_url
        @site_title = site_title
        @site_description = site_description
        @time = time
        @resource_url = resource_url

        @feature_name = feature_name
        @resource_url = resource_url

        @cancel_manager = cancel_manager

        if post
          @post_id = post.id
          @topic_id = post.topic_id
          @private_message = post.topic.private_message?
          @participants ||= post.topic.allowed_users.map(&:username).join(", ") if @private_message
          @user = post.user
        end
      end

      # these are strings that can be safely interpolated into templates
      TEMPLATE_PARAMS = %w[time site_url site_title site_description participants resource_url]

      def lookup_template_param(key)
        public_send(key.to_sym) if TEMPLATE_PARAMS.include?(key)
      end

      def time
        @time ||= Time.zone.now
      end

      def site_url
        @site_url ||= Discourse.base_url
      end

      def site_title
        @site_title ||= SiteSetting.title
      end

      def site_description
        @site_description ||= SiteSetting.site_description
      end

      def private_message?
        @private_message
      end

      def to_json
        {
          messages: @messages,
          topic_id: @topic_id,
          post_id: @post_id,
          private_message: @private_message,
          custom_instructions: @custom_instructions,
          username: @user&.username,
          user_id: @user&.id,
          participants: @participants,
          chosen_tools: @chosen_tools,
          message_id: @message_id,
          channel_id: @channel_id,
          context_post_ids: @context_post_ids,
          site_url: @site_url,
          site_title: @site_title,
          site_description: @site_description,
          skip_tool_details: @skip_tool_details,
          feature_name: @feature_name,
          resource_url: @resource_url,
        }
      end
    end
  end
end
