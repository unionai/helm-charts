from invoke import Collection
import tasks.builder.base as base

ns = Collection()
ns.add_collection(Collection.from_module(base), name="builder")
