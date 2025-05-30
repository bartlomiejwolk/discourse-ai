# frozen_string_literal: true

describe Plugin::Instance do
  before { SiteSetting.discourse_ai_enabled = true }

  describe "current_user_serializer#ai_helper_prompts" do
    fab!(:user)

    before do
      assign_fake_provider_to(:ai_helper_model)
      SiteSetting.ai_helper_enabled = true
      SiteSetting.ai_helper_illustrate_post_model = "disabled"
      Group.find_by(id: Group::AUTO_GROUPS[:admins]).add(user)

      DiscourseAi::AiHelper::Assistant.clear_prompt_cache!
    end

    let(:serializer) { CurrentUserSerializer.new(user, scope: Guardian.new(user)) }

    it "returns the available prompts" do
      expect(serializer.ai_helper_prompts).to be_present
      expect(serializer.ai_helper_prompts.object.count).to eq(8)
    end
  end
end
