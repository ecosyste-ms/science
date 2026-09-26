class SwhidJournalDispatcher
  CHECK_DELAY = 1.minute

  def dispatch(events)
    latest = events.group_by { |event| event.fetch("origin").downcase }
      .transform_values { |updates| updates.max_by { |event| event.fetch("date") } }
    return if latest.empty?

    Project.visible.scientific.with_repository
      .where("swhids->'archival'->>'status' = 'pending' AND swhids->'archival'->>'id' IS NOT NULL")
      .where("lower(swhids->'archival'->>'origin') IN (?)", latest.keys)
      .select(:id, :swhids).find_in_batches(batch_size: 1_000) do |projects|
        args = projects.filter_map do |project|
          request = project.swhids.fetch("archival")
          event = latest.fetch(request.fetch("origin").downcase)
          next unless Time.iso8601(event.fetch("date")) >= Time.iso8601(request.fetch("attempted_at"))
          next if request["journal_event"] && event.fetch("date") <= request["journal_event"].fetch("date")

          [project.id, request.fetch("id"), event]
        end
        next if args.empty?

        ids = Sidekiq::Client.push_bulk("class" => CheckSwhidVisitWorker, "args" => args,
          "at" => CHECK_DELAY.from_now.to_f)
        raise "SWH journal jobs were not queued" unless ids.size == args.size && ids.all?
      end
  end
end
