# frozen_string_literal: true

RSpec.describe Jobs::EmbeddingsBackfill do
  fab!(:second_topic) do
    topic = Fabricate(:topic, created_at: 1.year.ago, bumped_at: 2.day.ago)
    Fabricate(:post, topic: topic)
    topic
  end

  fab!(:first_topic) do
    topic = Fabricate(:topic, created_at: 1.year.ago, bumped_at: 1.day.ago)
    Fabricate(:post, topic: topic)
    topic
  end

  fab!(:third_topic) do
    topic = Fabricate(:topic, created_at: 1.year.ago, bumped_at: 3.day.ago)
    Fabricate(:post, topic: topic)
    topic
  end

  fab!(:vector_def) { Fabricate(:embedding_definition) }

  before do
    SiteSetting.ai_embeddings_selected_model = vector_def.id
    SiteSetting.ai_embeddings_enabled = true
    SiteSetting.ai_embeddings_backfill_batch_size = 1
    SiteSetting.ai_embeddings_per_post_enabled = true
    Jobs.run_immediately!
  end

  it "backfills topics based on bumped_at date" do
    embedding = Array.new(1024) { 1 }

    WebMock.stub_request(:post, "https://test.com/embeddings").to_return(
      status: 200,
      body: JSON.dump(embedding),
    )

    Jobs::EmbeddingsBackfill.new.execute({})

    topic_ids =
      DB.query_single("SELECT topic_id from #{DiscourseAi::Embeddings::Schema::TOPICS_TABLE}")

    expect(topic_ids).to eq([first_topic.id])

    # pulse again for the rest (and cover code)
    SiteSetting.ai_embeddings_backfill_batch_size = 100
    Jobs::EmbeddingsBackfill.new.execute({})

    topic_ids =
      DB.query_single("SELECT topic_id from #{DiscourseAi::Embeddings::Schema::TOPICS_TABLE}")

    expect(topic_ids).to contain_exactly(first_topic.id, second_topic.id, third_topic.id)

    freeze_time 1.day.from_now

    # new title forces a reindex
    third_topic.update!(updated_at: Time.zone.now, title: "new title - 123")

    Jobs::EmbeddingsBackfill.new.execute({})

    index_date =
      DB.query_single(
        "SELECT updated_at from #{DiscourseAi::Embeddings::Schema::TOPICS_TABLE} WHERE topic_id = ?",
        third_topic.id,
      ).first

    expect(index_date).to be_within_one_second_of(Time.zone.now)
  end
end
