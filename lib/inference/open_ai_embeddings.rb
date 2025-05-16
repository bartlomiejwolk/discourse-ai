# frozen_string_literal: true

module ::DiscourseAi
  module Inference
    class OpenAiEmbeddings
      def initialize(endpoint, api_key, model, dimensions)
        @endpoint = endpoint
        @api_key = api_key
        @model = model
        @dimensions = dimensions
      end

      attr_reader :endpoint, :api_key, :model, :dimensions

      def perform!(content)
        headers = {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{api_key}"
        }

        payload = { 
          model: model, 
          prompt: content  # Ollama uses 'prompt' instead of 'input'
        }
        payload[:dimensions] = dimensions if dimensions.present?

        conn = Faraday.new { |f| f.adapter FinalDestination::FaradayAdapter }
        response = conn.post(endpoint, payload.to_json, headers)

        case response.status
        when 200
          json = JSON.parse(response.body, symbolize_names: true)
          json[:embedding] or raise "Invalid Ollama response: missing embedding field"
        when 429
          nil # Rate limited
        else
          Rails.logger.warn(
            "Ollama Embeddings failed with status: #{response.status} body: #{response.body}",
          )
          raise Net::HTTPBadResponse.new(response.body.to_s)
        end
      end
    end
  end
end
