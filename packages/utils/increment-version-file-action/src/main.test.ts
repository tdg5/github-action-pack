import { promises as fs } from "fs";
import * as path from "path";

import { incrementVersion } from "github-action-pack-toolkit";
import { makeTempRepoWithRemote } from "github-action-pack-test-toolkit";

import { main } from "./main";

describe("main", () => {
  test("basic invocation", async () => {
    const initialVersion = "9.9.9";
    const commitMessage = "commitMessage";
    const authorEmail = "authorEmail";
    const authorName = "authorName";
    const versionFilePath = "versionFilePath";
    const versionFormat = "default";
    const { disposeCallback, remoteGit, repoPath } =
      await makeTempRepoWithRemote();
    try {
      const remoteInitialLog = (await remoteGit.log({ maxCount: 1 })).latest;
      if (remoteInitialLog === null) {
        throw Error("Failed to initialize remote repo");
      }
      const initialRef = (await remoteGit.status()).current;
      // Detach HEAD, because we can't push to a branch that is checked out
      await remoteGit.checkout({ "--detach": null });

      const versionFilePathFull = path.join(repoPath, versionFilePath);
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
      expect(newVersion).toBe(
        incrementVersion({
          format: versionFormat,
          version: initialVersion,
        }),
      );

      const remoteFinalLog = (
        await remoteGit.log({ from: initialRef, maxCount: 1 })
      ).latest;
      if (remoteFinalLog === null) {
        throw Error("Failed to fetch log from remote repo");
      }
      expect(remoteFinalLog.hash).not.toEqual(remoteInitialLog.hash);
      expect(remoteFinalLog.author_email).toEqual(authorEmail);
      expect(remoteFinalLog.author_name).toEqual(authorName);
      expect(remoteFinalLog.message).toEqual(commitMessage);
    } finally {
      disposeCallback();
    }
  });
});
