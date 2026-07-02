{{config( materialized = 'table')}}

select * from {{source('public','hourly')}}