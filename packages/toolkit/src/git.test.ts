import { promises as fs } from "fs";
import * as path from "path";

import {
  makeTempRepo,
  makeTempRepoWithRemote,
} from "github-action-pack-test-toolkit";
import { stageFiles, stageFilesAndCommitAndPush } from "./git";

describe("stageFiles", () => {
  test("basic invocation", async () => {
    const optionalFileName = "optional-file";
    const requiredFileName = "required-file";
    const { disposeCallback, git, repoPath } = await makeTempRepo();
    try {
      await fs.writeFile(
        path.join(repoPath, optionalFileName),
        optionalFileName,
      );
      await fs.writeFile(
        path.join(repoPath, requiredFileName),
        requiredFileName,
      );
      await stageFiles({
        optionalFiles: [optionalFileName],
        repoPath,
        requiredFiles: [requiredFileName],
      });
      const status = await git.status();
      expect(status.staged).toEqual([optionalFileName, requiredFileName]);
    } finally {
      await disposeCallback();
    }
  });

  test("required files are required", async () => {
    const optionalFileName = "optional-file";
    const requiredFileName = "required-file";
    const { disposeCallback, git, repoPath } = await makeTempRepo();
    try {
      await fs.writeFile(
        path.join(repoPath, requiredFileName),
        requiredFileName,
      );
      await git.add(requiredFileName);
      await git.commit("Add required file", [requiredFileName]);
      await fs.writeFile(
        path.join(repoPath, optionalFileName),
        optionalFileName,
      );
      const stageFilesPromise = stageFiles({
        optionalFiles: [optionalFileName],
        repoPath,
        requiredFiles: [requiredFileName],
      });
      await expect(stageFilesPromise).rejects.toEqual(
        Error(`Required file ${requiredFileName} had no differences to stage`),
      );
    } finally {
      await disposeCallback();
    }
  });

  test("optional files are optional", async () => {
    const optionalFileName = "optional-file";
    const requiredFileName = "required-file";
    const { disposeCallback, git, repoPath } = await makeTempRepo();
    try {
      await fs.writeFile(
        path.join(repoPath, optionalFileName),
        optionalFileName,
      );
      await git.add(optionalFileName);
      await git.commit("Add optional file", [optionalFileName]);
      await fs.writeFile(
        path.join(repoPath, requiredFileName),
        requiredFileName,
      );
      await stageFiles({
        optionalFiles: [optionalFileName],
        repoPath,
        requiredFiles: [requiredFileName],
      });
      const status = await git.status();
      expect(status.staged).toEqual([requiredFileName]);
    } finally {
      await disposeCallback();
    }
  });
});

describe("stageFilesAndCommitAndPush", () => {
  test("basic invocation", async () => {
    const optionalFileName = "optional-file";
    const requiredFileName = "required-file";
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

      await fs.writeFile(
        path.join(repoPath, optionalFileName),
        optionalFileName,
      );
      await fs.writeFile(
        path.join(repoPath, requiredFileName),
        requiredFileName,
      );
      const authorEmail = "author@email.com";
      const authorName = "Author Name";
      const commitMessage = "New commit";
      await stageFilesAndCommitAndPush({
        authorEmail,
        authorName,
        commitMessage,
        optionalFiles: [optionalFileName],
        repoPath,
        requiredFiles: [requiredFileName],
      });

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
      await disposeCallback();
    }
  });
});
