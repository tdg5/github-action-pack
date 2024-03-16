import { promises as fs } from "fs";
import * as path from "path";

import { stageFilesAndCommit } from "github-action-pack-toolkit";

import { makeTempRepoWithRemote } from "github-action-pack-test-toolkit";

import { main } from "./main";

describe("main", () => {
  test("basic invocation", async () => {
    const commitMessage = "commitMessage";
    const authorEmail = "authorEmail";
    const authorName = "authorName";
    const { disposeCallback, git, remoteGit, remoteRepoPath, repoPath } =
      await makeTempRepoWithRemote();
    try {
      const remoteInitialLog = (await remoteGit.log({ maxCount: 1 })).latest;
      if (remoteInitialLog === null) {
        throw Error("Failed to initialize remote repo");
      }

      const unchangedFilePath = "unchanged.txt";
      const unchangedFileRemotePathFull = path.join(
        remoteRepoPath,
        unchangedFilePath,
      );
      await fs.writeFile(unchangedFileRemotePathFull, "optional-1");

      const optionalFilePath = "optional.txt";
      const optionalFileRemotePathFull = path.join(
        remoteRepoPath,
        optionalFilePath,
      );
      const optionalFileLocalPathFull = path.join(repoPath, optionalFilePath);
      await fs.writeFile(optionalFileRemotePathFull, "optional-1");

      const requiredFilePath = "required.txt";
      const requiredFileRemotePathFull = path.join(
        remoteRepoPath,
        requiredFilePath,
      );
      const requiredFileLocalPathFull = path.join(repoPath, requiredFilePath);
      await fs.writeFile(requiredFileRemotePathFull, "required-1");

      await stageFilesAndCommit({
        authorEmail: "baseAuthorEmail",
        authorName: "baseAuthorName",
        commitMessage: "Commit test files",
        git: remoteGit,
        repoPath: remoteRepoPath,
        requiredFiles: [optionalFilePath, requiredFilePath, unchangedFilePath],
      });

      const baseRef = (await remoteGit.status()).current;
      // Detach HEAD, because we can't push to a branch that is checked out
      await remoteGit.checkout({ "--detach": null });

      await git.pull();

      await fs.writeFile(optionalFileLocalPathFull, "optional-2");
      await fs.writeFile(requiredFileLocalPathFull, "required-2");

      await main({
        context: { actor: "test@example.com", eventName: "push" },
        getInput: (key: string): string => {
          const inputs: { [key: string]: string } = {
            authorEmail,
            authorName,
            commitMessage,
            optionalFilePaths: `${optionalFilePath}\nunchanged.txt`,
            repoPath,
            requiredFilePaths: `${requiredFilePath}`,
          };
          return key in inputs ? inputs[key] : "";
        },
        log: (): void => {},
        setFailed: (): void => {},
      });

      const remoteFinalLog = (
        await remoteGit.log({ from: baseRef, maxCount: 1 })
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
