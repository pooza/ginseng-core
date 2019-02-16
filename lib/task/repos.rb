namespace :repos do
  desc 'update cert/gems'
  task update: ['cert:update', 'bundle:update']

  desc 'check cert/gems'
  task check: ['cert:check', 'bundle:check']
end
