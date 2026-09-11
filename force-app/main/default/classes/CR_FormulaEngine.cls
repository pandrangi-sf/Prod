public with sharing class CR_FormulaEngine {
    private static final Set<String> OPERATORS = new Set<String>{ '+', '-', '*', '/' };

    // DoS guards — caller-supplied expressions execute per row, so unbounded
    // length / depth would let a single bad formula stall the whole report.
    private static final Integer MAX_EXPRESSION_LENGTH = 4000;
    private static final Integer MAX_POSTFIX_CACHE_SIZE = 256;

    // Per-request postfix cache: avoids rebuilding the shunting-yard queue for
    // the same expression on every row. Apex statics reset per transaction.
    private static Map<String, List<String>> postfixCache = new Map<String, List<String>>();

    @AuraEnabled(cacheable=true)
    public static Object evaluateFormula(String formulaJson, String rowJson) {
        Map<String, Object> formula = (Map<String, Object>) JSON.deserializeUntyped(formulaJson);
        Map<String, Object> row = (Map<String, Object>) JSON.deserializeUntyped(rowJson);
        return evaluateFormulaMap(formula, row);
    }

    @AuraEnabled(cacheable=true)
    public static CR_Types.ValidationResult validateFormula(String formulaJson, String sampleRowJson) {
        CR_Types.ValidationResult result = new CR_Types.ValidationResult();
        try {
            Map<String, Object> formula = (Map<String, Object>) JSON.deserializeUntyped(formulaJson);
            if (String.isBlank(asString(formula.get('name'))) && String.isBlank(asString(formula.get('label')))) {
                result.addError('Formula name is required.');
            }
            if (String.isBlank(asString(formula.get('expression')))) {
                result.addError('Formula expression is required.');
            }
            Map<String, Object> sample = String.isBlank(sampleRowJson)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(sampleRowJson);
            if (result.valid) {
                evaluateFormulaMap(formula, sample);
            }
        } catch (Exception ex) {
            result.addError(ex.getMessage());
        }
        return result;
    }

    public static List<Map<String, Object>> applyFormulasAndBuckets(List<Map<String, Object>> rows, Map<String, Object> definition) {
        if (rows == null || rows.isEmpty() || definition == null) {
            return rows;
        }

        List<Object> formulas = asObjectList(definition.get('formulas'));
        List<Object> buckets = asObjectList(definition.get('buckets'));
        for (Map<String, Object> row : rows) {
            for (Object formulaObject : formulas) {
                Map<String, Object> formula = asMap(formulaObject);
                String name = firstNonBlank(new List<String>{ asString(formula.get('name')), asString(formula.get('label')) });
                if (String.isBlank(name)) {
                    continue;
                }
                row.put(name, evaluateFormulaMap(formula, row));
            }
            for (Object bucketObject : buckets) {
                applyBucket(asMap(bucketObject), row);
            }
        }
        return rows;
    }

    private static Object evaluateFormulaMap(Map<String, Object> formula, Map<String, Object> row) {
        String expression = asString(formula.get('expression'));
        String type = String.isBlank(asString(formula.get('type'))) ? 'number' : asString(formula.get('type')).toLowerCase();
        if (String.isBlank(expression)) {
            return null;
        }
        if (expression.length() > MAX_EXPRESSION_LENGTH) {
            throw new CR_ReportException('Formula expression exceeds ' + MAX_EXPRESSION_LENGTH + ' characters.');
        }
        // Cap cache size so hundreds of distinct formulas in one transaction don't
        // pile up unbounded heap.
        if (postfixCache.size() > MAX_POSTFIX_CACHE_SIZE) {
            postfixCache.clear();
        }
        if (expression.trim().toUpperCase().startsWith('IF(')) {
            return evaluateIf(expression.trim(), row);
        }
        if (expression.trim().toUpperCase().startsWith('CASE(')) {
            return evaluateCase(expression.trim(), row);
        }
        if (type == 'text') {
            return evaluateTextExpression(expression, row);
        }
        return evaluateNumberExpression(expression, row);
    }

    private static Object evaluateIf(String expression, Map<String, Object> row) {
        List<String> args = splitTopLevel(expression.substring(3, expression.length() - 1));
        if (args.size() != 3) {
            throw new AuraHandledException('IF formula requires condition, true value, and false value.');
        }
        return evaluateCondition(args[0], row) ? evaluateAny(args[1], row) : evaluateAny(args[2], row);
    }

    private static Object evaluateCase(String expression, Map<String, Object> row) {
        List<String> args = splitTopLevel(expression.substring(5, expression.length() - 1));
        if (args.size() < 4) {
            throw new AuraHandledException('CASE formula requires a source, at least one value/result pair, and a default.');
        }
        Object source = resolveToken(args[0].trim(), row);
        for (Integer i = 1; i < args.size() - 1; i += 2) {
            if (String.valueOf(source) == stripQuotes(args[i].trim())) {
                return evaluateAny(args[i + 1], row);
            }
        }
        return evaluateAny(args[args.size() - 1], row);
    }

    private static Object evaluateAny(String expression, Map<String, Object> row) {
        String trimmed = expression.trim();
        if ((trimmed.startsWith('\'') && trimmed.endsWith('\'')) || (trimmed.startsWith('"') && trimmed.endsWith('"'))) {
            return stripQuotes(trimmed);
        }
        if (trimmed.toUpperCase().startsWith('IF(')) {
            return evaluateIf(trimmed, row);
        }
        if (trimmed.toUpperCase().startsWith('CASE(')) {
            return evaluateCase(trimmed, row);
        }
        return evaluateNumberExpression(trimmed, row);
    }

    private static Decimal evaluateNumberExpression(String expression, Map<String, Object> row) {
        List<String> postfix = postfixCache.get(expression);
        if (postfix == null) {
            postfix = buildPostfix(expression);
            postfixCache.put(expression, postfix);
        }

        List<Decimal> stack = new List<Decimal>();
        for (String token : postfix) {
            if (!isOperator(token)) {
                stack.add(toDecimal(isNumber(token) ? token : resolveToken(token, row)));
                continue;
            }
            Decimal rightValue = stack.isEmpty() ? 0 : stack.remove(stack.size() - 1);
            Decimal leftValue = stack.isEmpty() ? 0 : stack.remove(stack.size() - 1);
            if (token == '+') stack.add(leftValue + rightValue);
            if (token == '-') stack.add(leftValue - rightValue);
            if (token == '*') stack.add(leftValue * rightValue);
            if (token == '/') stack.add(rightValue == 0 ? 0 : leftValue / rightValue);
        }
        return stack.isEmpty() ? 0 : stack[0];
    }

    @TestVisible
    private static List<String> buildPostfix(String expression) {
        List<String> output = new List<String>();
        List<String> operators = new List<String>();
        for (String token : tokenize(expression)) {
            if (String.isBlank(token)) {
                continue;
            }
            if (isNumber(token) || isIdentifier(token)) {
                output.add(token);
            } else if (isOperator(token)) {
                while (!operators.isEmpty() && precedence(operators[operators.size() - 1]) >= precedence(token)) {
                    output.add(operators.remove(operators.size() - 1));
                }
                operators.add(token);
            } else if (token == '(') {
                operators.add(token);
            } else if (token == ')') {
                while (!operators.isEmpty() && operators[operators.size() - 1] != '(') {
                    output.add(operators.remove(operators.size() - 1));
                }
                if (!operators.isEmpty()) {
                    operators.remove(operators.size() - 1);
                }
            }
        }
        while (!operators.isEmpty()) {
            output.add(operators.remove(operators.size() - 1));
        }
        return output;
    }

    private static String evaluateTextExpression(String expression, Map<String, Object> row) {
        // Distinct field tokens present in the row. A plain String.replace per token
        // is unsafe twice over: a field name that is a prefix of another (Amount vs
        // Amount_Adjusted) corrupts the longer one, and a substituted value that
        // happens to contain a field name gets re-substituted. We defend against
        // both by replacing the LONGEST names first into unique placeholders, then
        // expanding the placeholders to their values in a second pass.
        Set<String> seen = new Set<String>();
        List<String> names = new List<String>();
        for (String token : tokenize(expression)) {
            if (isIdentifier(token) && row.containsKey(token) && seen.add(token)) {
                names.add(token);
            }
        }
        // Order by descending length (lists are tiny — one entry per distinct field).
        for (Integer i = 0; i < names.size(); i++) {
            for (Integer j = i + 1; j < names.size(); j++) {
                if (names[j].length() > names[i].length()) {
                    String swap = names[i];
                    names[i] = names[j];
                    names[j] = swap;
                }
            }
        }
        String result = expression;
        Map<String, String> valueByPlaceholder = new Map<String, String>();
        for (Integer i = 0; i < names.size(); i++) {
            String placeholder = '\uE000' + i + '\uE001'; // private-use chars: can't occur in field names or values
            result = result.replace(names[i], placeholder);
            valueByPlaceholder.put(placeholder, String.valueOf(row.get(names[i])));
        }
        for (String placeholder : valueByPlaceholder.keySet()) {
            result = result.replace(placeholder, valueByPlaceholder.get(placeholder));
        }
        return stripQuotes(result);
    }

    private static Boolean evaluateCondition(String condition, Map<String, Object> row) {
        List<String> operators = new List<String>{ '>=', '<=', '!=', '=', '>', '<' };
        for (String operator : operators) {
            Integer index = condition.indexOf(operator);
            if (index <= 0) {
                continue;
            }
            Object leftValue = resolveToken(condition.substring(0, index).trim(), row);
            Object rightValue = resolveToken(condition.substring(index + operator.length()).trim(), row);
            Decimal leftNumber = toDecimal(leftValue);
            Decimal rightNumber = toDecimal(rightValue);
            if (operator == '=') return String.valueOf(leftValue) == String.valueOf(rightValue);
            if (operator == '!=') return String.valueOf(leftValue) != String.valueOf(rightValue);
            if (operator == '>') return leftNumber > rightNumber;
            if (operator == '>=') return leftNumber >= rightNumber;
            if (operator == '<') return leftNumber < rightNumber;
            if (operator == '<=') return leftNumber <= rightNumber;
        }
        return false;
    }

    private static void applyBucket(Map<String, Object> bucket, Map<String, Object> row) {
        String name = firstNonBlank(new List<String>{ asString(bucket.get('name')), asString(bucket.get('label')) });
        String sourceField = firstNonBlank(new List<String>{ asString(bucket.get('sourceField')), asString(bucket.get('field')) });
        if (String.isBlank(name) || String.isBlank(sourceField)) {
            return;
        }

        Object source = row.get(sourceField);
        String defaultValue = String.isBlank(asString(bucket.get('defaultValue'))) ? 'Other' : asString(bucket.get('defaultValue'));
        String selected = defaultValue;
        for (Object ruleObject : asObjectList(bucket.get('rules'))) {
            Map<String, Object> rule = asMap(ruleObject);
            String operator = asString(rule.get('operator'));
            Object value = rule.get('value');
            if (matches(source, operator, value, rule.get('valueTo'))) {
                selected = asString(rule.get('label'));
                break;
            }
        }
        row.put(name, selected);
    }

    private static Boolean matches(Object source, String operator, Object value, Object valueTo) {
        String normalized = String.isBlank(operator) ? '=' : operator.toUpperCase();
        Decimal sourceNumber = toDecimal(source);
        Decimal valueNumber = toDecimal(value);
        if (normalized == '=') return String.valueOf(source) == String.valueOf(value);
        if (normalized == '!=') return String.valueOf(source) != String.valueOf(value);
        if (normalized == '>') return sourceNumber > valueNumber;
        if (normalized == '>=') return sourceNumber >= valueNumber;
        if (normalized == '<') return sourceNumber < valueNumber;
        if (normalized == '<=') return sourceNumber <= valueNumber;
        if (normalized == 'BETWEEN') return sourceNumber >= valueNumber && sourceNumber <= toDecimal(valueTo);
        if (normalized == 'CONTAINS') return source != null && String.valueOf(source).contains(String.valueOf(value));
        return false;
    }

    private static Object resolveToken(String token, Map<String, Object> row) {
        String normalized = stripQuotes(token);
        if (row.containsKey(normalized)) {
            return row.get(normalized);
        }
        if (isNumber(normalized)) {
            return Decimal.valueOf(normalized);
        }
        return normalized;
    }

    private static List<String> tokenize(String expression) {
        List<String> tokens = new List<String>();
        String current = '';
        for (Integer i = 0; i < expression.length(); i++) {
            String character = expression.substring(i, i + 1);
            if (character == ' ') {
                if (!String.isBlank(current)) {
                    tokens.add(current);
                    current = '';
                }
            } else if (isOperator(character) || character == '(' || character == ')') {
                if (!String.isBlank(current)) {
                    tokens.add(current);
                    current = '';
                }
                tokens.add(character);
            } else {
                current += character;
            }
        }
        if (!String.isBlank(current)) {
            tokens.add(current);
        }
        return tokens;
    }

    private static List<String> splitTopLevel(String value) {
        List<String> parts = new List<String>();
        Integer depth = 0;
        String current = '';
        for (Integer i = 0; i < value.length(); i++) {
            String character = value.substring(i, i + 1);
            if (character == '(') depth++;
            if (character == ')') depth--;
            if (character == ',' && depth == 0) {
                parts.add(current.trim());
                current = '';
            } else {
                current += character;
            }
        }
        if (!String.isBlank(current)) {
            parts.add(current.trim());
        }
        return parts;
    }

    private static Integer precedence(String operator) {
        return operator == '*' || operator == '/' ? 2 : (operator == '+' || operator == '-' ? 1 : 0);
    }

    private static Boolean isIdentifier(String token) {
        return !String.isBlank(token) && !isOperator(token) && token != '(' && token != ')' && !isNumber(token);
    }

    private static Boolean isOperator(String token) {
        return token == '+' || token == '-' || token == '*' || token == '/';
    }

    private static Boolean isNumber(String token) {
        try {
            Decimal.valueOf(token);
            return true;
        } catch (Exception ex) {
            return false;
        }
    }

    private static Decimal toDecimal(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return 0;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception ex) {
            return 0;
        }
    }

    private static String stripQuotes(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        if ((trimmed.startsWith('\'') && trimmed.endsWith('\'')) || (trimmed.startsWith('"') && trimmed.endsWith('"'))) {
            return trimmed.substring(1, trimmed.length() - 1);
        }
        return trimmed;
    }

    private static List<Object> asObjectList(Object value) {
        if (value == null) return new List<Object>();
        if (value instanceof List<Object>) return (List<Object>) value;
        return new List<Object>{ value };
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static String firstNonBlank(List<String> values) {
        for (String value : values) {
            if (!String.isBlank(value)) return value;
        }
        return null;
    }
}