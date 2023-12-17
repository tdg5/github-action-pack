import { promises as fs } from "fs";
import * as path from "path";

import { jest } from "@jest/globals";

import { incrementVersion } from "github-action-pack-toolkit";
import { makeTempRepo } from "github-action-pack-test-toolkit";

import { main } from "./main";
import { incrementVersionFile } from "./incrementVersionFile";

describe("main", () => {
  test("basic invocation", async () => {
    const initialVersion = "9.9.9";
    const commitMessage = "commitMessage";
    const authorEmail = "authorEmail";
    const authorName = "authorName";
    const versionFilePath = "versionFilePath";
    const versionFormat = "default";
    const { disposeCallback, git, repoPath } = await makeTempRepo();
    try {
      const versionFilePathFull = path.join(repoPath, versionFilePath)
      await fs.writeFile(versionFilePathFull, initialVersion);

      await main({
        context: { actor: "test@example.com", eventName: "push" },
        getInput: (key: string): string => {
          const inputs: { [key: string]: string } = {
            authorEmail,
            authorName,
            commitMessage,
            repoPath,
            versionFilePath,
            versionFormat,
          };
          return key in inputs ? inputs[key] : "";
        },
        log: (): void => {},
        setFailed: (): void => {},
      });

      const newVersion = await fs.readFile(versionFilePathFull, "utf-8");
      expect(newVersion).toBe(incrementVersion({
        format: versionFormat,
        version: initialVersion,
      }));

      const lastCommit = (await git.log({maxCount: 1 })).latest!;
      expect(lastCommit.message).toEqual(commitMessage);
      expect(lastCommit.author_email).toEqual(authorEmail)
      expect(lastCommit.author_name).toEqual(authorName)
    }
    finally {
      disposeCallback();
    }
  });
});
