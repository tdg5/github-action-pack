import { context } from "@actions/github";
import { getInput, setFailed } from "@actions/core";

import { main } from "./main";

main({
  context,
  getInput,
  log: console.log,
  setFailed,
});
