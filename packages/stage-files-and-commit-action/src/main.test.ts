import { promises as fs } from "fs";
import * as path from "path";

import { stageFilesAndCommit } from "github-action-pack-toolkit";

import { makeTempRepo } from "github-action-pack-test-toolkit";

import { main } from "./main";

describe("main", () => {
  test("basic invocation", async () => {
    const commitMessage = "commitMessage";
    const authorEmail = "authorEmail";
    const authorName = "authorName";
    const { disposeCallback, git, repoPath } = await makeTempRepo();

    try {
      const unchangedFilePath = "unchanged.txt";
      const unchangedFilePathFull = path.join(repoPath, unchangedFilePath);
      await fs.writeFile(unchangedFilePathFull, "optional-1");

      const optionalFilePath = "optional.txt";
      const optionalFilePathFull = path.join(repoPath, optionalFilePath);
      const optionalFileLocalPathFull = path.join(repoPath, optionalFilePath);
      await fs.writeFile(optionalFilePathFull, "optional-1");

      const requiredFilePath = "required.txt";
      const requiredFilePathFull = path.join(repoPath, requiredFilePath);
      const requiredFileLocalPathFull = path.join(repoPath, requiredFilePath);
      await fs.writeFile(requiredFilePathFull, "required-1");

      await stageFilesAndCommit({
        authorEmail: "baseAuthorEmail",
        authorName: "baseAuthorName",
        commitMessage: "Commit test files",
        git: git,
        repoPath: repoPath,
        requiredFiles: [optionalFilePath, requiredFilePath, unchangedFilePath],
      });

      const baseRef = (await git.status()).current;

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
            requiredFilePaths: requiredFilePath,
          };
          return key in inputs ? inputs[key] : "";
        },
        log: (): void => {},
        setFailed: (): void => {},
      });

      const finalLog = (await git.log({ maxCount: 1 })).latest;
      if (finalLog === null) {
        throw Error("Failed to fetch log from repo");
      }
      expect(finalLog.hash).not.toEqual(baseRef);
      expect(finalLog.author_email).toEqual(authorEmail);
      expect(finalLog.author_name).toEqual(authorName);
      expect(finalLog.message).toEqual(commitMessage);
    } finally {
      disposeCallback();
    }
  });
});
