# frozen_string_literal: true

module DiscourseAi
  module AiHelper
    class Assistant
      IMAGE_CAPTION_MAX_WORDS = 50

      def self.prompt_cache
        @prompt_cache ||= ::DiscourseAi::MultisiteHash.new("prompt_cache")
      end

      def self.clear_prompt_cache!
        prompt_cache.flush!
      end

      def initialize(helper_llm: nil, image_caption_llm: nil)
        @helper_llm = helper_llm
        @image_caption_llm = image_caption_llm
      end

      def helper_llm
        @helper_llm || DiscourseAi::Completions::Llm.proxy(SiteSetting.ai_helper_model)
      end

      def image_caption_llm
        @image_caption_llm ||
          DiscourseAi::Completions::Llm.proxy(SiteSetting.ai_helper_image_caption_model)
      end

      def available_prompts(user)
        key = "prompt_cache_#{I18n.locale}"
        self
          .class
          .prompt_cache
          .fetch(key) do
            prompts = CompletionPrompt.where(enabled: true)

            # Hide illustrate_post if disabled
            prompts =
              prompts.where.not(
                name: "illustrate_post",
              ) if SiteSetting.ai_helper_illustrate_post_model == "disabled"

            prompts =
              prompts.map do |prompt|
                if prompt.name == "translate"
                  locale = user.effective_locale
                  locale_hash =
                    LocaleSiteSetting.language_names[locale] ||
                      LocaleSiteSetting.language_names[locale.split("_")[0]]
                  translation =
                    I18n.t(
                      "discourse_ai.ai_helper.prompts.translate",
                      language: locale_hash["nativeName"],
                    ) || prompt.translated_name || prompt.name
                else
                  translation =
                    I18n.t("discourse_ai.ai_helper.prompts.#{prompt.name}", default: nil) ||
                      prompt.translated_name || prompt.name
                end

                {
                  id: prompt.id,
                  name: prompt.name,
                  translated_name: translation,
                  prompt_type: prompt.prompt_type,
                  icon: icon_map(prompt.name),
                  location: location_map(prompt.name),
                }
              end
            prompts
          end
      end

      def custom_locale_instructions(user = nil, force_default_locale)
        locale = SiteSetting.default_locale
        locale = user.effective_locale if !force_default_locale && user
        locale_hash = LocaleSiteSetting.language_names[locale]

        if locale != "en" && locale_hash
          locale_description = "#{locale_hash["name"]} (#{locale_hash["nativeName"]})"
          "It is imperative that you write your answer in #{locale_description}, you are interacting with a #{locale_description} speaking user. Leave tag names in English."
        else
          nil
        end
      end

      def localize_prompt!(prompt, user = nil, force_default_locale: false)
        locale_instructions = custom_locale_instructions(user, force_default_locale)
        if locale_instructions
          prompt.messages[0][:content] = prompt.messages[0][:content] + locale_instructions
        end

        if prompt.messages[0][:content].include?("%LANGUAGE%")
          locale = SiteSetting.default_locale

          locale = user.effective_locale if user && !force_default_locale

          locale_hash = LocaleSiteSetting.language_names[locale]

          prompt.messages[0][:content] = prompt.messages[0][:content].gsub(
            "%LANGUAGE%",
            "#{locale_hash["name"]}",
          )
        end

        if user && prompt.messages[0][:content].include?("{{temporal_context}}")
          timezone = user.user_option.timezone || "UTC"
          current_time = Time.now.in_time_zone(timezone)

          temporal_context = {
            utc_date_time: current_time.iso8601,
            local_time: current_time.strftime("%H:%M"),
            user: {
              timezone: timezone,
              weekday: current_time.strftime("%A"),
            },
          }

          prompt.messages[0][:content] = prompt.messages[0][:content].gsub(
            "{{temporal_context}}",
            temporal_context.to_json,
          )

          prompt.messages.each do |message|
            message[:content] = DateFormatter.process_date_placeholders(message[:content], user)
          end
        end
      end

      def generate_prompt(completion_prompt, input, user, force_default_locale: false, &block)
        llm = helper_llm
        prompt = completion_prompt.messages_with_input(input)
        localize_prompt!(prompt, user, force_default_locale: force_default_locale)

        llm.generate(
          prompt,
          user: user,
          temperature: completion_prompt.temperature,
          stop_sequences: completion_prompt.stop_sequences,
          feature_name: "ai_helper",
          &block
        )
      end

      def generate_and_send_prompt(completion_prompt, input, user, force_default_locale: false)
        completion_result =
          generate_prompt(
            completion_prompt,
            input,
            user,
            force_default_locale: force_default_locale,
          )
        result = { type: completion_prompt.prompt_type }

        result[:suggestions] = (
          if completion_prompt.list?
            parse_list(completion_result).map { |suggestion| sanitize_result(suggestion) }
          else
            sanitized = sanitize_result(completion_result)
            result[:diff] = parse_diff(input, sanitized) if completion_prompt.diff?
            [sanitized]
          end
        )

        result
      end

      def stream_prompt(completion_prompt, input, user, channel, force_default_locale: false)
        streamed_diff = +""
        streamed_result = +""
        start = Time.now

        generate_prompt(
          completion_prompt,
          input,
          user,
          force_default_locale: force_default_locale,
        ) do |partial_response, cancel_function|
          streamed_result << partial_response

          streamed_diff = parse_diff(input, partial_response) if completion_prompt.diff?

          # Throttle updates and check for safe stream points
          if (streamed_result.length > 10 && (Time.now - start > 0.3)) || Rails.env.test?
            sanitized = sanitize_result(streamed_result)

            payload = { result: sanitized, diff: streamed_diff, done: false }
            publish_update(channel, payload, user)
            start = Time.now
          end
        end

        final_diff = parse_diff(input, streamed_result) if completion_prompt.diff?

        sanitized_result = sanitize_result(streamed_result)
        if sanitized_result.present?
          publish_update(channel, { result: sanitized_result, diff: final_diff, done: true }, user)
        end
      end

      def generate_image_caption(upload, user)
        prompt =
          DiscourseAi::Completions::Prompt.new(
            "You are a bot specializing in image captioning.",
            messages: [
              {
                type: :user,
                content: [
                  "Describe this image in a single sentence#{custom_locale_instructions(user)}",
                  { upload_id: upload.id },
                ],
              },
            ],
          )

        raw_caption =
          image_caption_llm.generate(
            prompt,
            user: user,
            max_tokens: 1024,
            feature_name: "image_caption",
          )

        raw_caption.delete("|").squish.truncate_words(IMAGE_CAPTION_MAX_WORDS)
      end

      private

      SANITIZE_REGEX_STR =
        %w[term context topic replyTo input output result]
          .map { |tag| "<#{tag}>\\n?|\\n?</#{tag}>" }
          .join("|")

      SANITIZE_REGEX = Regexp.new(SANITIZE_REGEX_STR, Regexp::IGNORECASE | Regexp::MULTILINE)

      def sanitize_result(result)
        result.gsub(SANITIZE_REGEX, "")
      end

      def publish_update(channel, payload, user)
        MessageBus.publish(channel, payload, user_ids: [user.id])
      end

      def icon_map(name)
        case name
        when "translate"
          "language"
        when "generate_titles"
          "heading"
        when "proofread"
          "spell-check"
        when "markdown_table"
          "table"
        when "tone"
          "microphone"
        when "custom_prompt"
          "comment"
        when "rewrite"
          "pen"
        when "explain"
          "question"
        when "illustrate_post"
          "images"
        when "replace_dates"
          "calendar-days"
        else
          nil
        end
      end

      def location_map(name)
        case name
        when "translate"
          %w[composer post]
        when "generate_titles"
          %w[composer]
        when "proofread"
          %w[composer post]
        when "markdown_table"
          %w[composer]
        when "tone"
          %w[composer]
        when "custom_prompt"
          %w[composer post]
        when "rewrite"
          %w[composer]
        when "explain"
          %w[post]
        when "summarize"
          %w[post]
        when "illustrate_post"
          %w[composer]
        when "replace_dates"
          %w[composer]
        else
          %w[]
        end
      end

      def parse_diff(text, suggestion)
        cooked_text = PrettyText.cook(text)
        cooked_suggestion = PrettyText.cook(suggestion)

        DiscourseDiff.new(cooked_text, cooked_suggestion).inline_html
      end

      def parse_list(list)
        Nokogiri::HTML5.fragment(list).css("item").map(&:text)
      end
    end
  end
end
