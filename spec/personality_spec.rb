# frozen_string_literal: true

RSpec.describe Personality do
  it "has a version number" do
    expect(Personality::VERSION).not_to be nil
  end

  it "defines an Error class" do
    expect(Personality::Error).to be < StandardError
  end
end
