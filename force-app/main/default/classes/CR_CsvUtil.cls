public with sharing class CR_CsvUtil {

    // Quote-wrap and escape a single CSV value. A real null becomes empty; the
    // literal string "null" is a legitimate value and is preserved.
    public static String escape(String value) {
        String safe = value == null ? '' : value;
        safe = safe.replace('"', '""');
        return '"' + safe + '"';
    }

    // Build a UTF-8 BOM + CRLF CSV string from query columns/rows, capped at
    // maxRows (null = all). CRLF + BOM so Excel on Windows opens it cleanly.
    public static String toCsvString(List<CR_Types.ColumnInfo> columns, List<Map<String, Object>> rows, Integer maxRows) {
        List<String> lines = new List<String>();
        List<String> header = new List<String>();
        if (columns != null) {
            for (CR_Types.ColumnInfo column : columns) {
                header.add(escape(column.label));
            }
        }
        lines.add(String.join(header, ','));

        if (rows != null && columns != null) {
            Integer shown = 0;
            for (Map<String, Object> row : rows) {
                if (maxRows != null && shown >= maxRows) {
                    break;
                }
                List<String> values = new List<String>();
                for (CR_Types.ColumnInfo column : columns) {
                    values.add(escape(String.valueOf(row.get(column.key))));
                }
                lines.add(String.join(values, ','));
                shown++;
            }
        }

        String bom = String.fromCharArray(new List<Integer>{ 65279 }); // U+FEFF
        return bom + String.join(lines, '\r\n');
    }
}