import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import type { Decorator } from "oxc-parser";
import { parseSync } from "oxc-parser";
import { walk } from "oxc-walker";
import { match, P } from "ts-pattern";
import { resolveAliasPath } from "./pathResolver";

/**
 * Walk a decorator's arguments and extract any DTOs thrown inside
 * class-validator pipes or guard classes that the decorator references.
 *
 * For example, `@UseGuards(AuthGuard)` → walks `AuthGuard`'s source,
 * finds `throw new UnauthorizedDto()`, and adds it to the throws list.
 */
export const extractDecoratorThrows = (
  decorator: Decorator,
  sourceFilePath: string,
): Array<{ className: string; filePath: string }> => {
  const throws: Array<{ className: string; filePath: string }> = [];

  if (decorator.expression.type !== "CallExpression") {
    return throws;
  }

  for (const arg of decorator.expression.arguments) {
    if (arg.type !== "Identifier") {
      continue;
    }

    const argName = arg.name;
    const sourceContent = readFileSync(sourceFilePath, "utf-8");
    const ast = parseSync(sourceFilePath, sourceContent);

    let importPath: string | null = null;

    walk(ast.program, {
      enter(node) {
        if (
          node.type === "ImportDeclaration" &&
          node.specifiers.some(
            (s) =>
              s.type === "ImportSpecifier" &&
              s.imported.type === "Identifier" &&
              s.imported.name === argName,
          )
        ) {
          importPath = node.source.value;
        }
      },
    });

    if (!importPath) {
      continue;
    }

    // Resolve relative to the file that wrote the decorator: a bare "" base
    // works for `paths` aliases but never for `../x/y` specifiers.
    const resolvedPath = resolveAliasPath(importPath, sourceFilePath);

    if (!resolvedPath) {
      throw new Error(`Unable to resolve import: ${importPath}`);
    }

    const classContent = readFileSync(resolvedPath, "utf-8");
    const classAst = parseSync(resolvedPath, classContent);

    // Build import map for the resolved file
    const dtoImports = new Map<string, string>();
    walk(classAst.program, {
      enter(node) {
        if (node.type === "ImportDeclaration") {
          for (const spec of node.specifiers) {
            if (
              spec.type === "ImportSpecifier" &&
              spec.imported.type === "Identifier"
            ) {
              let path = "";

              const resolved = resolveAliasPath(
                node.source.value,
                sourceFilePath,
              );
              if (resolved) {
                dtoImports.set(spec.imported.name, resolved);
              }
            }
          }
        }
      },
    });

    // Find throw statements in the resolved class file
    walk(classAst.program, {
      enter(node) {
        if (
          node.type === "ThrowStatement" &&
          node.argument?.type === "NewExpression" &&
          node.argument.callee.type === "Identifier"
        ) {
          const filePath = match(dtoImports.get(node.argument.callee.name))
            .with(P.string, (value) => value)
            .otherwise(() => {
              throw new Error(
                // @ts-expect-error AST node type narrowing
                `Could not resolve import for ${node.argument!.callee.name}`,
              );
            });

          throws.push({
            className: node.argument.callee.name,
            filePath,
          });
        }
      },
    });
  }

  return throws;
};
