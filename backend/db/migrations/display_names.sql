-- Display names become unique without regard to letter case. Where students
-- already share a name, the student who registered first keeps it and every
-- later one gets their student ID added, so the index below can be built.
UPDATE students s
SET display_name = left(s.display_name, 119 - char_length(s.id)) || ' ' || s.id
FROM (
    SELECT id, row_number() OVER (PARTITION BY lower(display_name) ORDER BY created_at, id) AS position
    FROM students
) ranked
WHERE ranked.id = s.id AND ranked.position > 1;

CREATE UNIQUE INDEX students_display_name_lower_key ON students (lower(display_name));
