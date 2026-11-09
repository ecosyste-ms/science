json.partial! 'api/v1/projects/project', project: @project
json.catalogue_included @project.catalogued?
json.catalogue_admission @project.catalogue_admission&.public_summary
