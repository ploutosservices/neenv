-- seed.sql — two made-up tenants in one MODx database, the backup's moment.
-- Loaded after schema.sql (MODx 3's table definitions, no rows). Nothing here is anyone's data.
INSERT INTO modx_context (`key`, name, description, rank) VALUES
  ('mgr', 'Manager', '', 0), ('web', 'Web', '', 0), ('alpha', 'Alpha', '', 1), ('beta', 'Beta', '', 2);
INSERT INTO modx_site_templates (id, templatename, content) VALUES (1, 'base', '[[*content]]'), (2, 'page', '<p>[[*content]]</p>');
INSERT INTO modx_site_tmplvars (id, name, caption, elements, default_text, properties, input_properties, output_properties)
  VALUES (1, 'hero', 'Hero', '', '', '', '', ''), (2, 'note', 'Note', '', '', '', '', '');
INSERT INTO modx_documentgroup_names (id, name) VALUES (1, 'members');
INSERT INTO modx_site_content (id, pagetitle, description, alias, parent, isfolder, content, template, context_key, uri) VALUES
  (10, 'Alpha home', '', 'index', 0, 1, 'alpha home, as backed up', 1, 'alpha', 'index.html'),
  (11, 'Alpha about', '', 'about', 10, 0, 'alpha about, as backed up', 2, 'alpha', 'about.html'),
  (12, 'Alpha news', '', 'news', 10, 0, 'alpha news, deleted later', 2, 'alpha', 'news.html'),
  (20, 'Beta home', '', 'index', 0, 1, 'beta home', 1, 'beta', 'index.html'),
  (21, 'Beta about', '', 'about', 20, 0, 'beta about, as backed up', 2, 'beta', 'about.html');
INSERT INTO modx_site_tmplvar_contentvalues (id, tmplvarid, contentid, value) VALUES
  (1, 1, 10, 'alpha hero'), (2, 2, 11, 'alpha note, as backed up'), (3, 1, 20, 'beta hero');
INSERT INTO modx_document_groups (id, document_group, document) VALUES (1, 1, 11), (2, 1, 21);
INSERT INTO modx_context_setting (context_key, `key`, value) VALUES
  ('alpha', 'site_start', '10'), ('alpha', 'site_name', 'Alpha, as backed up'), ('beta', 'site_start', '20'), ('beta', 'site_name', 'Beta');
INSERT INTO modx_context_resource (context_key, resource) VALUES ('alpha', 10), ('beta', 20);
INSERT INTO modx_system_settings (`key`, value) VALUES ('site_status', '1');
