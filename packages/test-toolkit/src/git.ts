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
  };

  return { disposeCallback, git, repoPath };
};
