module app;

import ddox.main;

import std.algorithm : any;
import std.string : endsWith;

int main(string[] args)
{
	auto extraArgs = args.any!((a) => a.endsWith("-html")) ? ["--std-macros=project.ddoc"] : [];

	return ddoxMain(args ~ extraArgs);
}
