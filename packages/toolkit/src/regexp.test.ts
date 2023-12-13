import * as regexp from "./regexp";

describe("escapePattern", () => {
  const allEscapeChars = [
    ".",
    "*",
    "+",
    "?",
    "$",
    "{",
    "}",
    "(",
    ")",
    "|",
    "[",
    "\\",
    "^",
    "]",
  ];

  test("escapes only expected characters", () => {
    const pattern =
      "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz[.*+?^${}()|]\\";
    const testPattern = pattern + pattern + pattern + pattern;
    let expectedResult = testPattern
      .replace(/[\\]/g, "\\\\")
      .replace(/[\^]/g, "\\^")
      .replace(/[\]]/g, "\\]");
    const escapeChars = allEscapeChars.filter((escapeChar) => {
      return escapeChar !== "\\" && escapeChar !== "^" && escapeChar !== "]";
    });

    escapeChars.forEach((escapeChar) => {
      expectedResult = expectedResult.replace(
        new RegExp(`[${escapeChar}]`, "g"),
        `\\${escapeChar}`,
      );
    });

    const result = regexp.escapePattern(testPattern);
    expect(result).toEqual(expectedResult);
  });

  test.each(allEscapeChars)(
    "an escaped pattern with %p matches that character",
    (escapeChar) => {
      const pattern = RegExp(regexp.escapePattern(escapeChar));
      expect(pattern.test(escapeChar)).toBe(true);
      allEscapeChars.forEach((otherEscapeChar) => {
        if (otherEscapeChar === escapeChar) {
          return;
        }
        expect(pattern.test(otherEscapeChar)).toBe(false);
      });
    },
  );
});
