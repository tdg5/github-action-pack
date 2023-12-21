import { promises as fs } from "fs";
import * as path from "path";

import { simpleGit, SimpleGit } from "simple-git";
import * as tmp from "tmp-promise";

interface TempRepo {
  disposeCallback: () => Promise<void>;
  git: SimpleGit;
  repoPath: string;
}

export const makeTempRepo = async (): Promise<TempRepo> => {
  const { path: repoPath, cleanup } = await tmp.dir();
  const git = simpleGit(repoPath);
  await git.init();

  const disposeCallback = async () => {
    const files = await fs.readdir(repoPath);
    for (const file of files) {
      await fs.rm(path.join(repoPath, file), { recursive: true });
    }
    await cleanup();
  }

  return { disposeCallback, git, repoPath };
};

interface TempRepoWithRemote extends TempRepo {
  remoteGit: SimpleGit;
  remoteRepoPath: string;
}

export const makeTempRepoWithRemote = async (): Promise<TempRepoWithRemote> => {
  const {
    disposeCallback: disposeCallbackRemote,
    git: remoteGit,
    repoPath: remoteRepoPath,
  } = await makeTempRepo();

  const readmePath = path.join(remoteRepoPath, "README.md");
  await fs.writeFile(readmePath, "Hello, World!");
  await remoteGit.add(readmePath);
  await remoteGit.commit("Initial commit", [readmePath]);

  const { path: repoPath, cleanup } = await tmp.dir();
  const git = simpleGit(repoPath);
  await git.clone(remoteRepoPath, repoPath);

  const disposeCallback = async () => {
    await disposeCallbackRemote();
    const files = await fs.readdir(repoPath);
    for (const file of files) {
      await fs.rm(path.join(repoPath, file), { recursive: true });
    }
    await cleanup();
  };

  return {
    disposeCallback,
    git,
    remoteGit,
    remoteRepoPath,
    repoPath,
  };
};
