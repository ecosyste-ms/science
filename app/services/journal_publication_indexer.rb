class JournalPublicationIndexer
  def sync!(record, entity)
    paper = if entity["eligible"] == false
      identity = PaperIdentifier.from_urls([entity.fetch("article_url")]).sole
      Paper.joins(:paper_identifiers).find_by(paper_identifiers: identity)
    else
      Paper.import_publication!(title: entity.fetch("title"), url: entity.fetch("article_url"),
        doi: entity["doi"], publication_date: entity["publication_date"])
    end
    return unless paper
    marker = { "source" => record.source, "source_identifier" => record.identifier }
    existing = paper.project_papers.lock.index_by(&:project_id)
    record.project_external_software_records.where(match_status: "matched").find_each do |source_link|
      link = existing.delete(source_link.project_id) || paper.project_papers.build(project_id: source_link.project_id, role: "software_description")
      evidence = source_link.evidence.map do |item|
        item.merge(marker).merge("url" => entity.fetch("article_url"), "relationship" => "software_description")
      end
      link.evidence = (link.evidence.reject { |item| item.slice(*marker.keys) == marker } + evidence).uniq
      link.save! if link.changed?
    end
    existing.each_value do |link|
      link.evidence = link.evidence.reject { |item| item.slice(*marker.keys) == marker }
      next unless link.changed?
      link.evidence.empty? ? link.destroy! : link.save!
    end
    paper
  end
end
