--liquibase formatted sql
--changeset MoeDaaboul:795f1910 stripComments:false runOnChange:true splitStatements:false
-- =============================================
-- Author:		zaher al sabbagh
-- Create date: 2015-10-26
-- Description:	get the first and second level for the delay spiff dashboard
-- =============================================
ALTER PROCEDURE [Report].[P_Report_GetInstantSpiffDashboardRetroSpiffHeader]
    -- Add the parameters for the stored procedure here
    @Account_ID INT,
    @CarrierID INT,
    @StartDate DATETIME,
    @EndDate DATETIME
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;

    -- Insert statements for procedure here




    SELECT
        o.OrderType_ID,
        o.Order_No AS [OrderNo],
        o1.Name AS [Product],
        o.DateDue AS [Date_Due],
        o.Reason,
        u.UserName,
        o.AuthNumber,
        CAST(o.DateOrdered AS DATETIME) AS [Date_Ordered],
        ISNULL(o2.Price, 0) AS [Price]
    FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
    JOIN dbo.Orders AS o1 WITH (READUNCOMMITTED)
        ON
            o1.Order_No = o.Order_No
            AND o1.ParentItemID = 0
    JOIN dbo.Orders AS o2 WITH (READUNCOMMITTED)
        ON
            o2.Order_No = o.Order_No
            AND o2.ParentItemID != 0
    JOIN dbo.Products AS p WITH (READUNCOMMITTED) ON o2.Product_ID = p.Product_ID
    JOIN dbo.Product_Category AS pc WITH (READUNCOMMITTED) ON pc.Product_ID = o1.Product_ID
    JOIN dbo.Categories AS cat WITH (READUNCOMMITTED) ON pc.Category_ID = cat.Category_ID
    JOIN dbo.Carrier_ID AS c WITH (READUNCOMMITTED) ON c.Category_ID = cat.Parent_ID
    JOIN users AS u WITH (READUNCOMMITTED) ON o.User_ID = u.User_ID
    JOIN dbo.Order_No AS o3 WITH (READUNCOMMITTED)
        ON
            o3.OrderType_ID IN (45, 46)
            AND o3.DateOrdered >= @StartDate
            AND o3.DateOrdered < @EndDate
            AND o3.Filled = 1
            AND o3.Process = 1
            AND o3.Void = 0
            AND CAST(o.Order_No AS NVARCHAR(50)) = o3.AuthNumber
    WHERE
        o.OrderType_ID IN (22, 23)
        AND o.DateOrdered < @EndDate
        AND o.DateOrdered >= DATEADD(DAY, -15, @StartDate)
        AND o.Filled = 1
        AND o.Process = 1
        AND o.Void = 0
        AND o2.Price != 0
        AND p.Product_Type = 4
        AND c.ID = @CarrierID
        AND o.Account_ID = @Account_ID


END
