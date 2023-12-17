import { promises as fs } from "fs";
import * as path from "path";

import { simpleGit, SimpleGit } from "simple-git";
import * as tmp from "tmp-promise";

import { makeTempRepo } from "github-action-pack-test-toolkit";
import { stageFiles } from "./git";

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
        requiredFiles: [requiredFileName],
        repoDir: repoPath,
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
        requiredFiles: [requiredFileName],
        repoDir: repoPath,
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
        requiredFiles: [requiredFileName],
        repoDir: repoPath,
      });
      const status = await git.status();
      expect(status.staged).toEqual([requiredFileName]);
    } finally {
      await disposeCallback();
    }
  });
});
