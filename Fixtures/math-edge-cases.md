# Math Edge Cases

Escaped dollars stay currency: \$5 and \$10.

An unclosed delimiter stays literal: $x + 1 has no closing dollar.

Broken math shows source plus a hint: $\frac{1}$ inline and below.

$$
\frac{1}
$$

Currency note: `$5 and $10` inside backticks is code, while bare $5 and $10
parses as math today — write `\$` when you mean money.

Adjacent display blocks keep their own anchors:

$$
a^2
$$

$$
b^2
$$
