import { incrementVersion } from "./VersionFormat";

describe("incrementVersion", () => {
  test.each([
    [{ format: "default", version: " 0.0.1-alpha-000 " }, "0.0.1-alpha-001"],
    [{ format: "default", version: "0.0.1-alpha-000" }, "0.0.1-alpha-001"],
    [{ format: "default", version: "0.0.1-alpha-001" }, "0.0.1-alpha-002"],
    [{ format: "default", version: "0.1.0-alpha-011" }, "0.1.0-alpha-012"],
    [{ format: "default", version: "1.0.0-alpha-111" }, "1.0.0-alpha-112"],
    [{ format: "default", version: "1.0.0-alpha-999" }, "1.0.0-alpha-1000"],
    [{ format: "default", version: "1.0.0-alpha-9999" }, "1.0.0-alpha-10000"],

    [{ format: "python", version: " 0.0.1a0 " }, "0.0.1a1"],
    [{ format: "python", version: "0.0.1a0" }, "0.0.1a1"],
    [{ format: "python", version: "0.0.1a1" }, "0.0.1a2"],
    [{ format: "python", version: "0.1.0a11" }, "0.1.0a12"],
    [{ format: "python", version: "1.0.0a111" }, "1.0.0a112"],
    [{ format: "python", version: "1.0.0a999" }, "1.0.0a1000"],
    [{ format: "python", version: "1.0.0a9999" }, "1.0.0a10000"],
    [{ format: "python", version: "1.0.0a9999" }, "1.0.0a10000"],
  ])(
    "handles alpha version %p as expected",
    ({ format, version }, expectedVersion) => {
      expect(incrementVersion({ format, version })).toBe(expectedVersion);
    },
  );

  test.each([
    [{ format: "default", version: " 0.0.1 " }, "0.0.2-alpha-000"],
    [{ format: "default", version: "0.1.0" }, "0.1.1-alpha-000"],
    [{ format: "default", version: "1.0.0" }, "1.0.1-alpha-000"],
    [{ format: "python", version: "0.0.1" }, "0.0.2a0"],
    [{ format: "python", version: "0.1.0" }, "0.1.1a0"],
    [{ format: "python", version: "1.0.0" }, "1.0.1a0"],
  ])(
    "handles release version %p as expected",
    ({ format, version }, expectedVersion) => {
      expect(incrementVersion({ format, version })).toBe(expectedVersion);
    },
  );
});
