import { findFilesRecursive } from "./findFilesRecursive";

// A `_`-prefixed directory is not part of the running app: it is where a
// checkout parks archived code (`back/src/modules/_backup`, excluded from
// `tsconfig.json`). Those copies keep imports that no longer resolve, and the
// decorator/types walk below throws on the first one it cannot resolve — so
// scanning them turns a cold cache into a boot failure.
export const findControllerFiles = (rootDir = "./src"): string[] => {
	return findFilesRecursive(
		rootDir,
		(filename: string) => filename.endsWith(".controller.ts"),
		(dirName: string) => dirName.startsWith("_"),
	);
};
