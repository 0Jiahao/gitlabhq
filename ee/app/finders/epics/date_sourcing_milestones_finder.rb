# frozen_string_literal: true

module Epics
  class DateSourcingMilestonesFinder
    include Gitlab::Utils::StrongMemoize

    FIELDS = [:id, :start_date, :due_date].freeze
    ID_INDEX = FIELDS.index(:id)
    START_DATE_INDEX = FIELDS.index(:start_date)
    DUE_DATE_INDEX = FIELDS.index(:due_date)

    def initialize(epic_id)
      @epic_id = epic_id
    end

    # rubocop: disable CodeReuse/ActiveRecord
    def execute
      strong_memoize(:execute) do
        Milestone.joins(issues: :epic_issue).where(epic_issues: { epic_id: epic_id }).joins(
          <<~SQL
            INNER JOIN (
              SELECT MIN(milestones.start_date) AS start_date, MAX(milestones.due_date) AS due_date
              FROM milestones
              INNER JOIN issues ON issues.milestone_id = milestones.id
              INNER JOIN epic_issues ON epic_issues.issue_id = issues.id
              WHERE epic_issues.epic_id = #{epic_id}
            ) inner_results ON (inner_results.start_date = milestones.start_date OR inner_results.due_date = milestones.due_date)
          SQL
        ).pluck(*FIELDS)
      end
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def start_date
      start_date_sourcing_milestone&.slice(START_DATE_INDEX)
    end

    def start_date_sourcing_milestone_id
      start_date_sourcing_milestone&.slice(ID_INDEX)
    end

    def due_date
      due_date_sourcing_milestone&.slice(DUE_DATE_INDEX)
    end

    def due_date_sourcing_milestone_id
      due_date_sourcing_milestone&.slice(ID_INDEX)
    end

    private

    attr_reader :epic_id

    def start_date_sourcing_milestone
      @start_date_sourcing_milestone ||= execute
        .reject { |row| row[START_DATE_INDEX].nil? }
        .min_by { |row| row[START_DATE_INDEX] }
    end

    def due_date_sourcing_milestone
      @due_date_sourcing_milestone ||= execute
        .reject { |row| row[DUE_DATE_INDEX].nil? }
        .max_by { |row| row[DUE_DATE_INDEX] }
    end
  end
end