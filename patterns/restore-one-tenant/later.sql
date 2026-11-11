-- later.sql — what happened after the backup: alpha's mistake, beta's work, and a
-- system setting. Restoring alpha must undo the first and keep the other two.
DELETE FROM modx_site_content WHERE id = 12;                                         -- alpha: a page deleted by mistake
UPDATE modx_site_content SET content = 'alpha about, overwritten' WHERE id = 11;      -- alpha: a page overwritten
UPDATE modx_site_tmplvar_contentvalues SET value = 'alpha note, overwritten' WHERE id = 2;
INSERT INTO modx_site_content (id, pagetitle, description, alias, parent, content, template, context_key, uri)
  VALUES (13, 'Alpha junk', '', 'junk', 10, 'alpha junk, after the backup', 2, 'alpha', 'junk.html');
INSERT INTO modx_site_tmplvar_contentvalues (id, tmplvarid, contentid, value) VALUES (4, 2, 13, 'alpha junk note');
UPDATE modx_context_setting SET value = 'Alpha, overwritten' WHERE context_key = 'alpha' AND `key` = 'site_name';
UPDATE modx_site_content SET content = 'beta about, edited after the backup' WHERE id = 21;   -- beta: real work
INSERT INTO modx_site_content (id, pagetitle, description, alias, parent, content, template, context_key, uri)
  VALUES (22, 'Beta new', '', 'new', 20, 'beta new page', 2, 'beta', 'new.html');
INSERT INTO modx_site_tmplvar_contentvalues (id, tmplvarid, contentid, value) VALUES (5, 2, 22, 'beta new note');
INSERT INTO modx_document_groups (id, document_group, document) VALUES (3, 1, 22);
UPDATE modx_context_setting SET value = 'Beta, renamed' WHERE context_key = 'beta' AND `key` = 'site_name';
UPDATE modx_system_settings SET value = '0' WHERE `key` = 'site_status';             -- outside every tenant
