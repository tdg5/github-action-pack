import { promises as fs } from "fs";

import * as tmp from "tmp-promise";

import { incrementVersion } from "github-action-pack-toolkit";
import { incrementVersionFile } from "./incrementVersionFile";

describe("incrementVersionFile", () => {
  test("basic invocaton", async () => {
    const versionFormat = "default";
    const { cleanup: cleanupCallback, path } = await tmp.file();
    const initialVersion = "9.9.9";
    await fs.writeFile(path, initialVersion);
    await incrementVersionFile({ versionFilePath: path, versionFormat });
    const newVersion = await fs.readFile(path, "utf-8");
    expect(newVersion).toBe(
      incrementVersion({
        format: versionFormat,
        version: initialVersion,
      }),
    );

    cleanupCallback();
  });
});
